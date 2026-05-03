import Foundation

struct AgentStep: Identifiable {
    let id = UUID()
    let index: Int
    let command: String
    let output: String      // trimmed probe output shown in UI
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
    private let maxSteps = 4

    /// Runs the agentic loop. Calls `onProgress` on each probe step.
    /// Returns the final command plus a log of every probe step taken.
    func run(
        query: String,
        files: [FileContext],
        cwd: String?,
        onProgress: @escaping (AgentProgress) -> Void
    ) async throws -> AgentResult {

        var steps: [AgentStep] = []
        var probeContext = ""   // accumulated "probe command → output" pairs

        for stepIndex in 1...maxSteps {
            let response = try await llm.generate(
                query: query,
                files: files,
                cwd: cwd,
                probeContext: probeContext,
                forceDirectAnswer: false
            )

            switch response {
            case .direct(let cmd):
                return AgentResult(command: cmd, steps: steps)

            case .probe(let probeCmd):
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

        // Exceeded max probes — force a direct answer with all gathered context
        onProgress(.finalizing)
        let final = try await llm.generate(
            query: query,
            files: files,
            cwd: cwd,
            probeContext: probeContext,
            forceDirectAnswer: true
        )
        if case .direct(let cmd) = final {
            return AgentResult(command: cmd, steps: steps)
        }
        throw LLMError.invalidResponse
    }
}
