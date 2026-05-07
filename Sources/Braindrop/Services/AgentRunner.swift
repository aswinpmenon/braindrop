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

enum TaskKind {
    /// User is asking ABOUT file content — extract text, answer with LLM (no shell command).
    case contentQuery
    /// Runtime lookup needed before acting (find largest then zip, etc.) — probe loop.
    case discovery
    /// Everything else — direct shell command via LLM.
    case simple
}

class AgentRunner {
    static let shared = AgentRunner()
    private init() {}

    private let llm      = LLMService.shared
    private let executor = CommandExecutor.shared
    private let maxSteps = 3

    // MARK: - Task classification

    func classifyTask(query: String, files: [FileContext]) -> TaskKind {
        let q = query.lowercased()

        // Content queries: user wants the LLM to READ and ANSWER about file contents.
        // These should NOT produce shell commands — they use the content answer path.
        let contentQueryVerbs = [
            "summarize", "summary", "tell me about", "what's in", "what does",
            "what is in", "describe", "analyse", "analyze", "explain",
            "translate", "transcribe", "what topic", "overview", "review",
            "what is this", "what are", "is this"
        ]
        let readableExts: Set<String> = [
            "pdf", "docx", "doc", "rtf", "txt", "md",
            "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt",
            "sh", "csv", "json", "xml", "yaml"
        ]
        let hasReadableFiles = files.contains { !$0.isDirectory && readableExts.contains($0.ext) }
        if hasReadableFiles && contentQueryVerbs.contains(where: { q.contains($0) }) {
            return .contentQuery
        }

        // Discovery: need runtime lookup before acting on a file
        let discoveryTriggers = [
            "zip the largest", "zip the newest", "zip the oldest", "zip the biggest",
            "move the largest", "move the newest", "move the oldest",
            "delete the largest", "copy the largest",
            "find and zip", "find and move", "find and copy",
            "find and delete", "find and rename", "find and compress",
            "duplicate", "duplicates", "find duplicate",
        ]
        if discoveryTriggers.contains(where: { q.contains($0) }) {
            return .discovery
        }

        return .simple
    }

    // MARK: - Content query: extract text → LLM text answer

    func answerContentQuery(query: String, files: [FileContext], cwd: String?) async throws -> String {
        let contents = await FileContentExtractor.extract(files: files)
        return try await llm.generateContentAnswer(
            query: query,
            files: files,
            cwd: cwd,
            extractedContents: contents
        )
    }

    // MARK: - Simple / discovery: generate shell command

    func run(
        query: String,
        files: [FileContext],
        cwd: String?,
        onProgress: @escaping (AgentProgress) -> Void
    ) async throws -> AgentResult {

        guard classifyTask(query: query, files: files) == .discovery else {
            // Simple task: one direct LLM call
            let resp = try await llm.generate(
                query: query, files: files, cwd: cwd,
                probeHistory: [], forceDirectAnswer: true
            )
            if case .direct(let cmd) = resp { return AgentResult(command: cmd, steps: []) }
            throw LLMError.invalidResponse
        }

        // Discovery: probe → observe → act using multi-turn conversation
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
                if probeCmd == lastProbeCmd { break }
                lastProbeCmd = probeCmd

                onProgress(.probing(step: stepIndex, command: probeCmd))

                let result = try await executor.executeProbe(command: probeCmd, workingDirectory: cwd)
                let out = result.displayOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedOut = String(out.prefix(2000).isEmpty ? "(no output)" : out.prefix(2000))

                steps.append(AgentStep(index: stepIndex, command: probeCmd, output: trimmedOut))
                probeHistory.append((cmd: probeCmd, output: trimmedOut))
            }
        }

        // Max probes reached — force a final answer
        onProgress(.finalizing)
        let final = try await llm.generate(
            query: query, files: files, cwd: cwd,
            probeHistory: probeHistory, forceDirectAnswer: true
        )
        if case .direct(let cmd) = final { return AgentResult(command: cmd, steps: steps) }
        throw LLMError.invalidResponse
    }
}
