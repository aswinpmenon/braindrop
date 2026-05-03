import Foundation

// MARK: - Errors

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

// MARK: - Response kind

enum LLMResponseKind {
    case direct(String)   // final shell command
    case probe(String)    // run this command to gather info, then call again
}

// MARK: - OpenAI wire types

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

struct LLMModel: Codable, Identifiable {
    let id: String
    var displayName: String { id.components(separatedBy: "/").last ?? id }
}

struct OpenAIModelsResponse: Codable {
    let data: [LLMModel]
}

// MARK: - Service

class LLMService {
    static let shared = LLMService()
    private let settings = AppSettings.shared
    private init() {}

    private var baseURL: URL { URL(string: settings.ollamaBaseURL)! }

    // MARK: - Main entry point (used by AgentRunner)

    func generate(
        query: String,
        files: [FileContext],
        cwd: String?,
        probeContext: String,
        forceDirectAnswer: Bool
    ) async throws -> LLMResponseKind {

        let system = buildSystemPrompt(files: files, cwd: cwd, allowProbe: !forceDirectAnswer)
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: system)]

        if probeContext.isEmpty {
            messages.append(ChatMessage(role: "user", content: query))
        } else {
            // Inject probe context into the user turn so the model sees what was gathered
            let userContent = """
            Task: \(query)

            Information gathered so far:
            \(probeContext)
            Now generate the final shell command.
            """
            messages.append(ChatMessage(role: "user", content: userContent))
        }

        let raw = try await callAPI(messages: messages, maxTokens: 150)
        let text = cleanResponse(raw)

        if !forceDirectAnswer && text.lowercased().hasPrefix("probe:") {
            let cmd = cleanCommand(String(text.dropFirst(6)))
            return .probe(cmd)
        }
        return .direct(cleanCommand(text))
    }

    // MARK: - Connection / model listing

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
           (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
        return false
    }

    // MARK: - Low-level API call

    private func callAPI(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        let request = ChatRequest(
            model: settings.ollamaModel,
            messages: messages,
            temperature: 0.1,
            max_tokens: maxTokens,
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
        guard let httpResponse = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.serverError(String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)")
        }
        guard let result = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let text = result.choices.first?.message.content else { throw LLMError.invalidResponse }
        return text
    }

    // MARK: - System prompt

    private func buildSystemPrompt(files: [FileContext], cwd: String?, allowProbe: Bool) -> String {
        // ── Context block ──────────────────────────────────────────────────
        var context = ""

        if !files.isEmpty {
            if let dir = cwd { context += "Working directory: \(dir)\n" }

            // Group files by type for multi-file intelligence
            let byKind = Dictionary(grouping: files) { $0.fileKind ?? $0.ext.uppercased() }
            if byKind.keys.count > 1 {
                let summary = byKind.map { kind, group in
                    "\(group.count)× \(kind)"
                }.joined(separator: ", ")
                context += "Selected: \(summary), total \(files.count) files\n"
            }

            context += "Files:\n"
            files.forEach { context += "  • \($0.contextLine)\n" }

            // Total size hint
            let totalBytes = files.compactMap(\.size).reduce(0, +)
            if totalBytes > 0 {
                context += "  Total: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))\n"
            }
        } else if let dir = cwd {
            context += "Current folder: \(dir)\n"
            context += "No files selected — operate on folder contents.\n"
        }

        // ── File-specific rules ────────────────────────────────────────────
        let fileRules: String
        if files.isEmpty {
            fileRules = """
            - Folder operations: use "\(cwd ?? ".")" as root path.
            - For all files of a type: glob "\(cwd ?? ".")/*.ext" or use find.
            """
        } else {
            fileRules = """
            - Use the exact file paths listed above.
            - For batch ops on multiple files use a shell loop or space-separated paths.
            """
        }

        // ── Probe protocol (only injected when the AgentRunner enables it) ───
        let probeSection = allowProbe ? """

        AGENTIC MODE — you may need one discovery step first:
        If you must know a specific filename or size at runtime before acting, output:
        PROBE: <shell command>
        You will receive the output and then produce the final command.
        Only use PROBE when the exact target file is unknown (e.g. "largest file", "oldest file").
        Never use PROBE for counting, summarising, converting, or any task where the file path is already known.
        """ : ""

        return """
        You are a macOS terminal expert. Output ONE shell command that fulfils the user's request.

        CONTEXT:
        \(context)
        TOOL REFERENCE (use the right tool for the task):
        PDF text    → pdftotext "file.pdf" - | wc -w          (word count)
                    → pdftotext "file.pdf" "out.txt"           (extract text)
                    → pdfseparate -f 1 -l 3 "in.pdf" "pg%d.pdf" (split pages, needs: brew install poppler)
                    → pdfunite p1.pdf p2.pdf "out.pdf"         (merge PDFs)
                    → gs -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -o "out.pdf" "in.pdf" (compress)
        PDF info    → pdfinfo "file.pdf"  |  mdls -name kMDItemNumberOfPages "file.pdf"
        Images      → sips -Z 1024 "img.jpg"                   (resize, built-in)
                    → sips -s format jpeg "img.png" --out "img.jpg" (convert, built-in)
                    → sips -g pixelWidth -g pixelHeight "img.jpg"   (dimensions)
        Video       → ffmpeg -i "in.mov" "out.mp4"             (convert)
                    → ffmpeg -i "in.mp4" -vn "out.mp3"         (extract audio)
                    → ffprobe -v quiet -show_format "file.mp4"  (info)
        Archives    → zip "out.zip" "file"  |  unzip "a.zip" -d "dir/"
        Text/count  → wc -w "file"  |  wc -l "file"  |  wc -c "file"
        Metadata    → mdls "file"  |  exiftool "file"  |  file "file"
        Docs        → textutil -convert txt "file.docx"        (built-in)
        \(fileRules)
        STRICT RULES:
        - Output ONLY the shell command. No prose, no markdown, no code fences.
        - Quote every path with double quotes.
        - Single line only.
        - Never use grep to read PDF content — use pdftotext first.
        \(probeSection)
        """
    }

    // MARK: - Response cleaning

    private func cleanResponse(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["<|im_end|>", "<|im_start|>", "<|endoftext|>", "</s>"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanCommand(_ raw: String) -> String {
        var cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cmd.hasPrefix("```") {
            let lines = cmd.components(separatedBy: "\n")
            cmd = lines.dropFirst().prefix(while: { !$0.hasPrefix("```") })
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cmd.hasPrefix("`") && cmd.hasSuffix("`") && cmd.count > 2 {
            cmd = String(cmd.dropFirst().dropLast())
        }
        // Safety net: strip PROBE: if the model leaks it into a forced-direct-answer turn
        for prefix in ["probe:", "command:", "shell command:", "$ ", "% ", "bash\n", "sh\n", "zsh\n"] {
            if cmd.lowercased().hasPrefix(prefix) {
                cmd = String(cmd.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let firstLine = cmd.components(separatedBy: "\n")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? cmd
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
