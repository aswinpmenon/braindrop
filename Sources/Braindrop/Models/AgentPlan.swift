import Foundation

struct PlanStep: Codable, Identifiable {
    let id: Int
    let description: String
    let command: String
}

struct AgentPlan: Codable {
    let summary: String
    let steps: [PlanStep]
}

struct StepResult: Identifiable {
    let id = UUID()
    let step: PlanStep
    let output: String
    let succeeded: Bool
}
