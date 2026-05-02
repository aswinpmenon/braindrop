import Foundation

enum LLMError: LocalizedError {
    case connectionFailed(String)
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let url): return "Cannot connect to LLM server at \(url). Is it running?"
        case .invalidResponse: return "Received an invalid response from the LLM server."
        case .serverError(let msg): return msg
        }
    }
}

// OpenAI-compatible request/response types (works with llama-server AND Ollama /v1 endpoint)
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

// For llama-server model info
struct OllamaModel: Codable, Identifiable {
    var id: String { name }
    let name: String
    let modified_at: String?
    let size: Int64?
    var displayName: String { name }
}

struct OllamaTagsResponse: Codable {
    let models: [OllamaModel]
}

// Keeping OllamaService name for compatibility
class OllamaService {
    static let shared = OllamaService()
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
            max_tokens: 256,
            stream: false
        )

        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url, timeoutInterval: 90)
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

    func listModels() async throws -> [OllamaModel] {
        // llama-server returns just the loaded model name from /health
        let healthURL = baseURL.appendingPathComponent("health")
        if let (_, resp) = try? await URLSession.shared.data(from: healthURL),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            return [OllamaModel(name: settings.ollamaModel, modified_at: nil, size: nil)]
        }
        // Ollama: /api/tags
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "GET"
        if let (data, response) = try? await URLSession.shared.data(for: req),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let decoded = try? JSONDecoder().decode(OllamaTagsResponse.self, from: data) {
            return decoded.models
        }
        return [OllamaModel(name: settings.ollamaModel, modified_at: nil, size: nil)]
    }

    func checkConnection() async -> Bool {
        // llama-server: GET /health → 200 {"status":"ok"}
        // Ollama:       GET /api/tags → 200
        for path in ["health", "api/tags"] {
            var req = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 5)
            req.httpMethod = "GET"
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
        }
        return false
    }

    private func buildSystemPrompt(files: [FileContext], cwd: String?) -> String {
        var context = ""
        if let dir = cwd { context += "Working directory: \(dir)\n" }
        if !files.isEmpty {
            context += "Selected files:\n"
            files.forEach { context += "  - \($0.path)\n" }
        }

        return """
        You are a macOS shell command generator. Your job is to convert natural language requests into a single executable shell command.

        \(context.isEmpty ? "" : "CONTEXT:\n\(context)\n")Rules:
        - Output ONLY the shell command. No explanation, no markdown, no code blocks, no prefixes.
        - Use the exact file paths from the context above.
        - Wrap all file paths in double quotes.
        - Use standard macOS tools (ffmpeg, sips, python3, bc, zip, tar, exiftool, etc.)
        - For multiple files, use appropriate loops or glob patterns.
        - Prefer creating new output files rather than overwriting originals, unless the user explicitly asks to replace.
        - Output a single line command only.
        """
    }

    private func cleanCommand(_ raw: String) -> String {
        var cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip triple-backtick code fences
        if cmd.hasPrefix("```") {
            let lines = cmd.components(separatedBy: "\n")
            cmd = lines.dropFirst().prefix(while: { !$0.hasPrefix("```") }).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip single-backtick wrapping: `command`
        if cmd.hasPrefix("`") && cmd.hasSuffix("`") && cmd.count > 2 {
            cmd = String(cmd.dropFirst().dropLast())
        }
        // Strip common LLM prefixes
        for prefix in ["Command:", "Shell command:", "$ ", "% ", "bash\n", "sh\n", "zsh\n"] {
            if cmd.lowercased().hasPrefix(prefix.lowercased()) {
                cmd = String(cmd.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Take only the first non-empty line if multiple lines returned
        let firstLine = cmd.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? cmd
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
