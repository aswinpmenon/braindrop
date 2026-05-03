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

    /// `probeHistory` is a list of (probeCommand, probeOutput) pairs from prior steps.
    /// Using proper multi-turn assistant/user turns so the model reasons about each result.
    func generate(
        query: String,
        files: [FileContext],
        cwd: String?,
        probeHistory: [(cmd: String, output: String)],
        forceDirectAnswer: Bool
    ) async throws -> LLMResponseKind {

        let allowProbe = !forceDirectAnswer && probeHistory.isEmpty
        let system = buildSystemPrompt(files: files, cwd: cwd, allowProbe: allowProbe)
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: system)]

        // First user turn is always the raw query
        messages.append(ChatMessage(role: "user", content: query))

        // Replay each probe step as proper assistant → user turns
        for (index, step) in probeHistory.enumerated() {
            messages.append(ChatMessage(role: "assistant", content: "PROBE: \(step.cmd)"))
            let isLast = index == probeHistory.count - 1
            let followUp = isLast
                ? "Command output:\n\(step.output)\n\nNow output ONLY the final shell command to complete the task."
                : "Command output:\n\(step.output)\n\nContinue."
            messages.append(ChatMessage(role: "user", content: followUp))
        }

        let raw = try await callAPI(messages: messages, maxTokens: 160)
        let text = cleanResponse(raw)

        // Only parse PROBE: on the first call (no prior history, probe allowed)
        if allowProbe && text.lowercased().hasPrefix("probe:") {
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

        // ── Probe protocol (only injected when AgentRunner enables it) ──────
        let probeSection = allowProbe ? """

        AGENTIC MODE:
        If you must discover which file to act on before you can write the command, output:
        PROBE: <command that returns ONLY the file path or data you need>
        You will see the output and then produce the final command.
        IMPORTANT: The PROBE command must ONLY return information — never include the action (zip, move, delete) in the probe.
        After seeing the probe output you write the action command separately.
        Example — "zip the largest file":
          PROBE: find "DIR" -maxdepth 1 -type f -exec du -b {} + | sort -rn | head -1 | awk '{print $2}'
          (probe returns: /path/bigfile.mp4)
          Final command: zip "bigfile.zip" "/path/bigfile.mp4"
        """ : ""

        return """
        You are a macOS shell expert. Output ONE shell command that fulfils the request.

        CONTEXT:
        \(context)
        COMMAND PATTERNS — match the task to the right pattern:

        Find largest file  → find "DIR" -maxdepth 1 -type f -exec du -sh {} + | sort -rh | head -1
        Find newest file   → find "DIR" -maxdepth 1 -type f -newer /tmp -exec ls -lt {} + | head -2
        Find oldest file   → find "DIR" -maxdepth 1 -type f -exec ls -lt {} + | tail -1
        Count files        → find "DIR" -maxdepth 1 -type f | wc -l
        Count by type      → find "DIR" -maxdepth 1 -name "*.pdf" | wc -l
        Disk usage         → du -sh "DIR"  |  du -sh "DIR"/* | sort -rh | head -10
        NEVER use ls -l | sort to find file sizes — ls output is not sortable by size.

        PDF word count     → pdftotext "file.pdf" - | wc -w
        PDF page count     → pdfinfo "file.pdf" | grep Pages
        PDF extract text   → pdftotext "file.pdf" "out.txt"
        PDF split pages    → pdfseparate -f 1 -l 5 "in.pdf" "page-%d.pdf"
        PDF merge          → pdfunite a.pdf b.pdf "out.pdf"
        PDF compress       → gs -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -q -o "out.pdf" "in.pdf"
        NEVER use grep or strings to read PDF text — always use pdftotext.

        Image resize       → sips -Z 1024 "img.jpg"
        Image convert      → sips -s format jpeg "img.png" --out "img.jpg"
        Image dimensions   → sips -g pixelWidth -g pixelHeight "img.jpg"
        Image compress     → sips -s formatOptions 70 "img.jpg" --out "compressed.jpg"
        Batch resize       → for f in "DIR"/*.jpg; do sips -Z 800 "$f"; done

        Video convert      → ffmpeg -i "in.mov" -c:v libx264 "out.mp4"
        Extract audio      → ffmpeg -i "in.mp4" -vn -q:a 0 "out.mp3"
        Video trim         → ffmpeg -i "in.mp4" -ss 00:01:00 -to 00:02:30 -c copy "clip.mp4"
        Video info         → ffprobe -v quiet -print_format json -show_format -show_streams "file.mp4"

        File metadata      → mdls "file"  |  exiftool "file"  |  file "file"
        Word/line count    → wc -w "file"  |  wc -l "file"
        Doc to text        → textutil -convert txt "file.docx"
        Archive            → zip -r "out.zip" "folder/"  |  tar czf "out.tar.gz" "folder/"
        \(fileRules)
        RULES:
        - Output ONLY the shell command. No explanation, no markdown, no code fences.
        - Wrap every path in double quotes.
        - Single line only.
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
