import Foundation

class PlanExecutor {
    static let shared = PlanExecutor()
    private let executor = CommandExecutor.shared
    private let llm = LLMService.shared
    private init() {}

    func planFor(
        query: String,
        files: [FileContext],
        cwd: String?,
        extractedContents: [ExtractedContent]
    ) async throws -> AgentPlan {
        return try await llm.generatePlan(
            query: query,
            files: files,
            cwd: cwd,
            extractedContents: extractedContents
        )
    }

    func executePlan(
        _ plan: AgentPlan,
        cwd: String?,
        onStep: @escaping (Int, Int, String) -> Void
    ) async throws -> [StepResult] {
        var results: [StepResult] = []
        let total = plan.steps.count
        for (index, step) in plan.steps.enumerated() {
            onStep(index + 1, total, step.command)
            let r = try await executor.execute(command: step.command, workingDirectory: cwd)
            results.append(StepResult(step: step, output: r.displayOutput, succeeded: r.succeeded))
            if !r.succeeded { break }
        }
        return results
    }
}
