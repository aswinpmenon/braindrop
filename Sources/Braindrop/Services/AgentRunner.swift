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
    private let maxSteps = 2   // conservative — 1.5B model loops if given more rope

    func run(
        query: String,
        files: [FileContext],
        cwd: String?,
        onProgress: @escaping (AgentProgress) -> Void
    ) async throws -> AgentResult {

        // Gate: only allow probing for queries that genuinely need file discovery.
        // Simple queries go straight to a direct answer — no probing, no delay.
        guard needsProbing(query: query) else {
            let resp = try await llm.generate(
                query: query, files: files, cwd: cwd,
                probeContext: "", forceDirectAnswer: true
            )
            if case .direct(let cmd) = resp { return AgentResult(command: cmd, steps: []) }
            throw LLMError.invalidResponse
        }

        // Agentic loop for queries that genuinely need runtime discovery
        var steps: [AgentStep] = []
        var probeContext = ""
        var lastProbeCmd = ""

        for stepIndex in 1...maxSteps {
            let response = try await llm.generate(
                query: query, files: files, cwd: cwd,
                probeContext: probeContext, forceDirectAnswer: false
            )

            switch response {
            case .direct(let cmd):
                return AgentResult(command: cmd, steps: steps)

            case .probe(let probeCmd):
                // Safety: if model returns the same probe twice, stop looping
                if probeCmd == lastProbeCmd {
                    break
                }
                lastProbeCmd = probeCmd

                onProgress(.probing(step: stepIndex, command: probeCmd))
                let result = try await executor.executeProbe(command: probeCmd, workingDirectory: cwd)
                let out = result.displayOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(2000)
                let trimmedOut = out.isEmpty ? "(no output)" : String(out)

                steps.append(AgentStep(index: stepIndex, command: probeCmd, output: trimmedOut))
                probeContext += "\n[Step \(stepIndex)] $ \(probeCmd)\n\(trimmedOut)\n"
            }
        }

        // Exceeded max probes — force final answer with all gathered context
        onProgress(.finalizing)
        let final = try await llm.generate(
            query: query, files: files, cwd: cwd,
            probeContext: probeContext, forceDirectAnswer: true
        )
        if case .direct(let cmd) = final {
            return AgentResult(command: cmd, steps: steps)
        }
        throw LLMError.invalidResponse
    }

    // Only enable the probe loop for tasks that must discover file names, sizes,
    // or other runtime information that isn't already in FileContext.
    private func needsProbing(query: String) -> Bool {
        let q = query.lowercased()
        let triggers = [
            "largest", "smallest", "biggest", "heaviest",
            "newest", "oldest", "most recent", "latest",
            "find and", "find the", "which file", "which files",
            "duplicate", "duplicates", "find duplicate",
            "most files", "fewest", "longest", "shortest"
        ]
        return triggers.contains { q.contains($0) }
    }
}
