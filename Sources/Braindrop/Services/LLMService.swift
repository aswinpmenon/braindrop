import Foundation

// MARK: - Errors

enum LLMError: LocalizedError {
    case connectionFailed(String)
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let url): return "Cannot connect to MLX server at \(url). Is it running?"
        case .invalidResponse: return "The model returned an unexpected response."
        case .serverError(let msg): return msg
        }
    }
}

// MARK: - Response kind

enum LLMResponseKind {
    case direct(String)   // final shell command
    case probe(String)    // run this to gather info, then call again
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

// MARK: - SSE streaming types

private struct StreamDelta: Codable {
    let choices: [StreamChoice]
}
private struct StreamChoice: Codable {
    let delta: DeltaContent
}
private struct DeltaContent: Codable {
    let content: String?
}

// MARK: - Service

class LLMService {
    static let shared = LLMService()
    private let settings = AppSettings.shared
    private init() {}

    private var baseURL: URL { URL(string: settings.ollamaBaseURL)! }

    // MARK: - Shell command generation (used by AgentRunner for simple/discovery tasks)

    func generate(
        query: String,
        files: [FileContext],
        cwd: String?,
        probeHistory: [(cmd: String, output: String)],
        forceDirectAnswer: Bool
    ) async throws -> LLMResponseKind {

        let allowProbe = !forceDirectAnswer && probeHistory.isEmpty
        let system = buildCommandPrompt(files: files, cwd: cwd, allowProbe: allowProbe)
        var messages: [ChatMessage] = [ChatMessage(role: "system", content: system)]
        messages.append(ChatMessage(role: "user", content: query))

        for (index, step) in probeHistory.enumerated() {
            messages.append(ChatMessage(role: "assistant", content: "PROBE: \(step.cmd)"))
            let isLast = index == probeHistory.count - 1
            let followUp = isLast
                ? "Output:\n\(step.output)\n\nNow output ONLY the final shell command."
                : "Output:\n\(step.output)\n\nContinue."
            messages.append(ChatMessage(role: "user", content: followUp))
        }

        let raw = try await callAPI(messages: messages, maxTokens: 180)
        let text = cleanResponse(raw)

        if allowProbe && text.lowercased().hasPrefix("probe:") {
            return .probe(cleanCommand(String(text.dropFirst(6))))
        }
        return .direct(cleanCommand(text))
    }

    // MARK: - Streaming shell command (simple tasks — shows tokens live)

    func generateStreaming(
        query: String,
        files: [FileContext],
        cwd: String?,
        onToken: @escaping (String) -> Void
    ) async throws -> String {
        let system = buildCommandPrompt(files: files, cwd: cwd, allowProbe: false)
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: query)
        ]
        do {
            let raw = try await callStreamingAPI(messages: messages, maxTokens: 180, onToken: onToken)
            return cleanCommand(cleanResponse(raw))
        } catch {
            // Streaming not supported by server — fall back to non-streaming
            let raw = try await callAPI(messages: messages, maxTokens: 180)
            return cleanCommand(cleanResponse(raw))
        }
    }

    // MARK: - Content answer (used by AgentRunner for contentQuery tasks)

    func generateContentAnswer(
        query: String,
        files: [FileContext],
        cwd: String?,
        extractedContents: [ExtractedContent]
    ) async throws -> String {
        let system = buildContentAnswerPrompt(files: files, extractedContents: extractedContents)
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: query)
        ]
        let raw = try await callAPI(messages: messages, maxTokens: 500)
        return cleanResponse(raw)
    }

    // MARK: - Plan generation (used by PlanExecutor for multi-step content actions)

    func generatePlan(
        query: String,
        files: [FileContext],
        cwd: String?,
        extractedContents: [ExtractedContent]
    ) async throws -> AgentPlan {
        let system = buildPlanPrompt(files: files, cwd: cwd, extractedContents: extractedContents)
        let messages = [
            ChatMessage(role: "system", content: system),
            ChatMessage(role: "user", content: query)
        ]
        let raw = try await callAPI(messages: messages, maxTokens: 512)
        return try parsePlan(cleanResponse(raw))
    }

    private func parsePlan(_ text: String) throws -> AgentPlan {
        var json = text
        if let start = text.range(of: "```json\n"), let end = text.range(of: "\n```") {
            json = String(text[start.upperBound..<end.lowerBound])
        } else if let start = text.range(of: "{"),
                  let end = text.range(of: "}", options: .backwards),
                  start.lowerBound <= end.upperBound {
            json = String(text[start.lowerBound...end.upperBound])
        }
        guard let data = json.data(using: .utf8),
              let plan = try? JSONDecoder().decode(AgentPlan.self, from: data) else {
            throw LLMError.invalidResponse
        }
        return plan
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

    // MARK: - Low-level: non-streaming

    private func callAPI(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        let request = ChatRequest(
            model: settings.ollamaModel, messages: messages,
            temperature: 0.1, max_tokens: maxTokens, stream: false
        )
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url, timeoutInterval: 60)
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

    // MARK: - Low-level: SSE streaming

    private func callStreamingAPI(
        messages: [ChatMessage],
        maxTokens: Int,
        onToken: @escaping (String) -> Void
    ) async throws -> String {
        let request = ChatRequest(
            model: settings.ollamaModel, messages: messages,
            temperature: 0.1, max_tokens: maxTokens, stream: true
        )
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            throw LLMError.connectionFailed(settings.ollamaBaseURL)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.invalidResponse
        }

        var accumulated = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            if json == "[DONE]" { break }
            if let data = json.data(using: .utf8),
               let chunk = try? JSONDecoder().decode(StreamDelta.self, from: data),
               let token = chunk.choices.first?.delta.content, !token.isEmpty {
                accumulated += token
                onToken(token)
            }
        }
        return accumulated
    }

    // MARK: - System prompt: shell command mode

    private func buildCommandPrompt(files: [FileContext], cwd: String?, allowProbe: Bool) -> String {
        let tools = ToolAvailability.shared

        // ── Context ────────────────────────────────────────────────────────
        var context = ""
        if !files.isEmpty {
            if let dir = cwd { context += "Working directory: \(dir)\n" }
            context += "Selected files (use EXACT paths below — do NOT reconstruct paths):\n"
            for file in files {
                var meta: [String] = []
                if let kind = file.fileKind { meta.append(kind) }
                if !file.humanSize.isEmpty  { meta.append(file.humanSize) }
                if let m = file.extraMeta   { meta.append(m) }
                let suffix = meta.isEmpty ? "" : " [\(meta.joined(separator: ", "))]"
                context += "  \"\(file.path)\"\(suffix)\n"
            }
        } else if let dir = cwd {
            context += "Working directory: \"\(dir)\"\n"
            context += "No files selected — operate on the folder.\n"
        }

        let toolStatus = tools.promptSummary()
        if !toolStatus.isEmpty { context += "Tools: \(toolStatus)\n" }

        // ── File path rule ─────────────────────────────────────────────────
        let fileRule: String
        if files.isEmpty {
            fileRule = "Use \"\(cwd ?? ".")\" as root. For all files of a type: find \"\(cwd ?? ".")\" -maxdepth 1 -name \"*.ext\""
        } else {
            let paths = files.map { "\"\($0.path)\"" }.joined(separator: " ")
            fileRule = "EXACT paths to use: \(paths)"
        }

        // ── Probe section ──────────────────────────────────────────────────
        let probeSection = allowProbe ? """

        PROBE MODE: If you must discover a runtime value first, output:
        PROBE: <command returning ONLY the needed data, no action>
        Then output the final command after seeing probe output.
        """ : ""

        return """
        You are a macOS Finder assistant. Output ONE shell command. No explanation, no markdown, no code fences.

        CONTEXT:
        \(context)
        ── ALWAYS AVAILABLE (macOS built-in) ─────────────────────────────

        Images (sips — ALWAYS use "jpeg" not "jpg" as format name):
          PNG→JPG:     sips -s format jpeg "photo.png" --out "photo.jpg"
          JPG→PNG:     sips -s format png "photo.jpg" --out "photo.png"
          JPG→TIFF:    sips -s format tiff "photo.jpg" --out "photo.tiff"
          PNG→GIF:     sips -s format gif "photo.png" --out "photo.gif"
          Resize:      sips -Z 1024 "img.jpg"
          Resize+save: sips -Z 1024 "img.jpg" --out "img_sm.jpg"
          Info:        sips -g pixelWidth -g pixelHeight "img.jpg"
          Compress:    sips -s formatOptions low "img.jpg" --out "small.jpg"
          Batch conv:  for f in *.png; do sips -s format jpeg "$f" --out "${f%.png}.jpg"; done
          Strip EXIF:  sips --deleteProperty all "img.jpg"
          CRITICAL: format must be one of: jpeg png gif bmp tiff — never "jpg"

        Documents — textutil (txt rtf rtfd html doc docx odt — NOT pdf):
          RTF→DOCX:    textutil -convert docx "file.rtf" -output "out.docx"
          DOCX→TXT:    textutil -convert txt "file.docx" -output "out.txt"
          TXT→HTML:    textutil -convert html "file.txt" -output "out.html"
          Word count:  wc -w "file.txt"

        Audio — afconvert (always available):
          →M4A/AAC:    afconvert -f m4af -d aac "in.wav" "out.m4a"
          →WAV:        afconvert -f WAVE -d LEI16 "in.m4a" "out.wav"
          →AIFF:       afconvert -f AIFF -d BEI16 "in.mp3" "out.aiff"
          Info:        afinfo "file.m4a"

        File operations:
          Metadata:    mdls "file"  |  file "file"  |  xattr -l "file"
          Count:       wc -w "file"  |  wc -l "file"  |  find "DIR" -type f | wc -l
          Disk:        du -sh "file"  |  find "DIR" -type f -exec du -sh {} + | sort -rh | head -10
          Archive:     zip -r "out.zip" "folder/"  |  tar czf "out.tgz" "folder/"
          Extract:     unzip "arch.zip" -d "dir/"  |  tar xzf "arch.tgz" -C "dir/"
          Open:        open "file"  |  open -a "AppName" "file"  |  open -R "file"
          Rename:      mv "old.ext" "new.ext"
          Batch rename:for f in "DIR"/*.jpg; do mv "$f" "${f%.jpg}_v2.jpg"; done
          Copy path:   echo "/full/path" | pbcopy
          New folder:  mkdir -p "DIR/NewFolder"

        Finder / macOS automation (osascript — always available):
          Set colour label (0=none 1=orange 2=red 3=yellow 4=blue 5=purple 6=green 7=gray):
                       osascript -e 'tell app "Finder" to set label index of (POSIX file "PATH" as alias) to 2'
          Tag:         tag -a "TagName" "file"
          Get selection path:
                       osascript -e 'tell app "Finder" to get POSIX path of (selection as alias)'
          Screenshot:  screencapture -x "~/Desktop/shot.png"

        ── INSTALLED / AUTO-INSTALLABLE TOOLS ───────────────────────────

        PDF:
          Pages:       mdls -name kMDItemNumberOfPages "file.pdf"
          →TXT:        pdftotext "in.pdf" "out.txt"
          Word count:  pdftotext "file.pdf" - | wc -w
          Split:       pdfseparate -f 1 -l 5 "in.pdf" "page-%d.pdf"
          Merge:       pdfunite a.pdf b.pdf "out.pdf"
          Compress:    gs -sDEVICE=pdfwrite -dPDFSETTINGS=/ebook -q -o "out.pdf" "in.pdf"
          →DOCX:       pandoc "in.pdf" -o "out.docx"

        Spreadsheet / Office → PDF (libreoffice):
          xlsx→PDF:    soffice --headless --convert-to pdf "file.xlsx" --outdir "OUTDIR"
          numbers→PDF: osascript -e 'tell app "Numbers" to export front document to POSIX file "out.pdf" as PDF'
          csv→PDF:     soffice --headless --convert-to pdf "file.csv" --outdir "OUTDIR"
          Any office→PDF: soffice --headless --convert-to pdf "file.docx" --outdir "OUTDIR"

        Video (ffmpeg):
          Convert:     ffmpeg -i "in.mov" -c:v libx264 "out.mp4"
          Audio only:  ffmpeg -i "in.mp4" -vn -q:a 0 "out.mp3"
          Trim:        ffmpeg -i "in.mp4" -ss 00:01:00 -to 00:02:30 -c copy "clip.mp4"
          Gif:         ffmpeg -i "in.mp4" -vf "fps=10,scale=640:-1" "out.gif"
          Info:        ffprobe -v quiet -print_format json -show_format -show_streams "file.mp4"

        Other:
          Metadata:    exiftool "file"
          OCR:         tesseract "img.png" "out"   (outputs out.txt)
          Download:    yt-dlp "URL"

        ── RULES ─────────────────────────────────────────────────────────
        \(fileRule)
        - Single line only. Double-quote ALL paths.
        - Always output the REAL command for the task (soffice, ffmpeg, pandoc, etc).
        - NEVER output echo or fallback commands. The app auto-installs missing tools.
        - For spreadsheet→PDF use soffice (LibreOffice); set OUTDIR to the file's directory.\(probeSection)
        """
    }

    // MARK: - System prompt: content answer mode

    private func buildContentAnswerPrompt(files: [FileContext], extractedContents: [ExtractedContent]) -> String {
        var context = "File information:\n"
        for file in files {
            var meta: [String] = []
            if let kind = file.fileKind { meta.append(kind) }
            if !file.humanSize.isEmpty  { meta.append(file.humanSize) }
            if let m = file.extraMeta   { meta.append(m) }
            let suffix = meta.isEmpty ? "" : " (\(meta.joined(separator: ", ")))"
            context += "  \(file.name)\(suffix)\n"
        }

        if !extractedContents.isEmpty {
            context += "\nContent:\n"
            for ec in extractedContents {
                context += "--- \(ec.filename) ---\n\(ec.content)\n"
                if ec.truncated { context += "[content truncated]\n" }
            }
        } else {
            context += "\n(File content could not be extracted — answer based on metadata only.)\n"
        }

        return """
        You are a helpful assistant. Answer the user's question about the file(s) below.
        Be concise and direct. 2-5 sentences. Plain text only — no markdown, no shell commands.

        \(context)
        """
    }

    // MARK: - System prompt: plan mode

    private func buildPlanPrompt(files: [FileContext], cwd: String?, extractedContents: [ExtractedContent]) -> String {
        var context = ""
        if let dir = cwd { context += "Working directory: \(dir)\n" }
        context += "Files:\n"
        for file in files {
            context += "  \"\(file.path)\" [\(file.fileKind ?? file.ext.uppercased())]\n"
        }
        if !extractedContents.isEmpty {
            context += "\nContent (first \(FileContentExtractor.maxChars) chars):\n"
            for ec in extractedContents {
                context += "=== \(ec.filename) ===\n\(ec.content)\n"
                if ec.truncated { context += "[truncated]\n" }
            }
        }
        return """
        You are a macOS shell expert. Output a JSON execution plan for the user's request.
        \(context)
        JSON format (no markdown, no explanation):
        {"summary":"one-line description","steps":[{"id":1,"description":"...","command":"shell command"},{"id":2,"description":"...","command":"..."}]}

        Rules: valid JSON only, single-line commands, double-quote all paths, max 5 steps.
        """
    }

    // MARK: - Response cleaning

    func cleanResponse(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["<|im_end|>", "<|im_start|>", "<|endoftext|>", "</s>", "<|end|>"] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cleanCommand(_ raw: String) -> String {
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
