import Foundation

enum LLMError: LocalizedError {
    case connectionFailed(String)
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let url): return "Cannot connect to MLX server at \(url). Is it running?"
        case .invalidResponse: return "Received an invalid response from the MLX server."
        case .serverError(let msg): return msg
        }
    }
}

// OpenAI-compatible request/response types
struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let max_tokens: Int
    let stream: Bool
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatResponse: Codable {
    let choices: [ChatChoice]
}

struct ChatChoice: Codable {
    let message: ChatMessage
}

// OpenAI /v1/models response
struct LLMModel: Codable, Identifiable {
    let id: String
    var displayName: String { id.components(separatedBy: "/").last ?? id }
}

struct OpenAIModelsResponse: Codable {
    let data: [LLMModel]
}

class LLMService {
    static let shared = LLMService()
    private let settings = AppSettings.shared
    private init() {}

    private var baseURL: URL { URL(string: settings.ollamaBaseURL)! }

    func generateCommand(query: String, files: [FileContext], workingDirectory: String?) async throws -> String {
        let systemPrompt = buildSystemPrompt(files: files, cwd: workingDirectory)
        let request = ChatRequest(
            model: settings.ollamaModel,
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: query)
            ],
            temperature: 0.1,
            max_tokens: 128,
            stream: false
        )

        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw LLMError.connectionFailed(settings.ollamaBaseURL)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw LLMError.serverError(msg)
        }

        guard let result = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let text = result.choices.first?.message.content else {
            throw LLMError.invalidResponse
        }

        return cleanCommand(text)
    }

    func listModels() async throws -> [LLMModel] {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"), timeoutInterval: 5)
        req.httpMethod = "GET"
        if let (data, response) = try? await URLSession.shared.data(for: req),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) {
            return decoded.data
        }
        return [LLMModel(id: settings.ollamaModel)]
    }

    func checkConnection() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/models"), timeoutInterval: 5)
        req.httpMethod = "GET"
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            return true
        }
        return false
    }

    private func buildSystemPrompt(files: [FileContext], cwd: String?) -> String {
        var context = ""

        if !files.isEmpty {
            if let dir = cwd { context += "Working directory: \(dir)\n" }
            context += "Selected files:\n"
            files.forEach { context += "  - \($0.path)\n" }
        } else if let dir = cwd {
            context += "Current folder: \(dir)\n"
            context += "No files are selected. Operate on the folder or its contents.\n"
        }

        let fileRules = files.isEmpty ? """
        - When asked about counts, sizes, or listing: use the current folder path above.
        - For operations on all files in the folder, use glob patterns like "\(cwd ?? ".")"/*.ext
        """ : """
        - Use the exact selected file paths listed above.
        - For multiple files, use loops or space-separated paths as appropriate.
        """

        return """
        You are a macOS shell command generator. Convert the user's request into a single executable shell command.

        CONTEXT:
        \(context)
        RULES:
        - Output ONLY the shell command. No explanation, no markdown, no code blocks, no prefixes.
        - Wrap all file and folder paths in double quotes.
        - Use standard macOS tools (ls, find, wc, du, ffmpeg, sips, python3, bc, zip, tar, exiftool, etc.)
        \(fileRules)
        - Prefer creating new output files rather than overwriting originals, unless asked.
        - Output a single line only.
        """
    }

    private func cleanCommand(_ raw: String) -> String {
        var cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip Qwen/chat-template special tokens
        for token in ["<|im_end|>", "<|im_start|>", "<|endoftext|>", "</s>"] {
            cmd = cmd.replacingOccurrences(of: token, with: "")
        }
        cmd = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip triple-backtick code fences
        if cmd.hasPrefix("```") {
            let lines = cmd.components(separatedBy: "\n")
            cmd = lines.dropFirst().prefix(while: { !$0.hasPrefix("```") }).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip single-backtick wrapping
        if cmd.hasPrefix("`") && cmd.hasSuffix("`") && cmd.count > 2 {
            cmd = String(cmd.dropFirst().dropLast())
        }
        // Strip common LLM prefixes
        for prefix in ["Command:", "Shell command:", "$ ", "% ", "bash\n", "sh\n", "zsh\n"] {
            if cmd.lowercased().hasPrefix(prefix.lowercased()) {
                cmd = String(cmd.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let firstLine = cmd.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? cmd
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
