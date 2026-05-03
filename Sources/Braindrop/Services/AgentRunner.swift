import Foundation

struct AgentStep: Identifiable {
    let id = UUID()
    let index: Int
    let command: String
    let output: String
}

struct AgentResult {
    let command: String
    let steps: [AgentStep]
}

enum AgentProgress {
    case probing(step: Int, command: String)
    case finalizing
}

class AgentRunner {
    static let shared = AgentRunner()
    private init() {}

    private let llm      = LLMService.shared
    private let executor = CommandExecutor.shared
    private let maxSteps = 3

    func run(
        query: String,
        files: [FileContext],
        cwd: String?,
        onProgress: @escaping (AgentProgress) -> Void
    ) async throws -> AgentResult {

        // Simple tasks: skip agentic loop entirely — one LLM call, instant response.
        guard needsProbing(query: query) else {
            let resp = try await llm.generate(
                query: query, files: files, cwd: cwd,
                probeHistory: [], forceDirectAnswer: true
            )
            if case .direct(let cmd) = resp { return AgentResult(command: cmd, steps: []) }
            throw LLMError.invalidResponse
        }

        // Agentic loop: probe → observe → act, using proper multi-turn conversation.
        var steps: [AgentStep] = []
        var probeHistory: [(cmd: String, output: String)] = []
        var lastProbeCmd = ""

        for stepIndex in 1...maxSteps {
            let response = try await llm.generate(
                query: query, files: files, cwd: cwd,
                probeHistory: probeHistory, forceDirectAnswer: false
            )

            switch response {
            case .direct(let cmd):
                return AgentResult(command: cmd, steps: steps)

            case .probe(let probeCmd):
                // Stop if the model is stuck repeating the same probe
                if probeCmd == lastProbeCmd { break }
                lastProbeCmd = probeCmd

                onProgress(.probing(step: stepIndex, command: probeCmd))

                let result = try await executor.executeProbe(command: probeCmd, workingDirectory: cwd)
                let out = result.displayOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedOut = String(out.prefix(2000).isEmpty ? "(no output)" : out.prefix(2000))

                steps.append(AgentStep(index: stepIndex, command: probeCmd, output: trimmedOut))
                probeHistory.append((cmd: probeCmd, output: trimmedOut))
            }
        }

        // Max probes reached — force a final answer with all gathered context.
        onProgress(.finalizing)
        let final = try await llm.generate(
            query: query, files: files, cwd: cwd,
            probeHistory: probeHistory, forceDirectAnswer: true
        )
        if case .direct(let cmd) = final { return AgentResult(command: cmd, steps: steps) }
        throw LLMError.invalidResponse
    }

    // Probe only for tasks where the target can't be embedded in a single pipeline.
    // "find the largest file and zip it" needs to know the filename before zipping.
    // "how many files", "word count", "convert this" — all solvable without probing.
    private func needsProbing(query: String) -> Bool {
        let q = query.lowercased()
        let triggers = [
            // "find X then do something else to it" — need name at runtime
            "zip the largest", "zip the newest", "zip the oldest", "zip the biggest",
            "move the largest", "move the newest", "move the oldest",
            "delete the largest", "copy the largest",
            "find and zip", "find and move", "find and copy",
            "find and delete", "find and rename", "find and compress",
            // Genuinely need runtime comparison
            "duplicate", "duplicates", "find duplicate",
        ]
        return triggers.contains { q.contains($0) }
    }
}
