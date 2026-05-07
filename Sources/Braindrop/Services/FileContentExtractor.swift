import Foundation
import PDFKit

struct ExtractedContent {
    let path: String
    let content: String
    let truncated: Bool
    var filename: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum FileContentExtractor {
    static let maxChars = 2500
    private static let deadlineNs: UInt64 = 500_000_000

    static func extract(files: [FileContext]) async -> [ExtractedContent] {
        await withTaskGroup(of: ExtractedContent?.self) { group in
            for file in files where isReadable(file.ext) && !file.isDirectory {
                group.addTask { await racedExtract(file) }
            }
            var results: [ExtractedContent] = []
            for await result in group {
                if let r = result { results.append(r) }
            }
            return results
        }
    }

    static func isReadable(_ ext: String) -> Bool {
        let set: Set<String> = [
            "pdf", "docx", "doc", "rtf", "pages",
            "txt", "md", "csv", "json", "xml", "yaml", "yml",
            "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java", "kt",
            "sh", "bash", "zsh",
            "mp4", "mov", "avi", "mkv", "webm", "mp3", "wav", "aac", "flac", "m4a"
        ]
        return set.contains(ext)
    }

    // Race extraction against a 500ms deadline.
    private static func racedExtract(_ file: FileContext) async -> ExtractedContent? {
        await withTaskGroup(of: ExtractedContent?.self) { group in
            group.addTask { await extractSingle(file) }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadlineNs)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func extractSingle(_ file: FileContext) async -> ExtractedContent? {
        switch file.ext {
        case "pdf":
            // Use PDFKit first (no external tools needed), shell fallback
            if let result = extractPDFWithPDFKit(file.path) { return result }
            return await shellExtract(cmd: "pdftotext \"\(file.path)\" -", path: file.path)

        case "docx", "doc", "rtf", "pages":
            return await shellExtract(cmd: "textutil -convert txt -stdout \"\(file.path)\"", path: file.path)

        case "mp4", "mov", "avi", "mkv", "webm", "mp3", "wav", "aac", "flac", "m4a":
            return await shellExtract(
                cmd: "ffprobe -v quiet -print_format json -show_format -show_streams \"\(file.path)\"",
                path: file.path
            )

        default:
            // Plain text / source code
            guard let raw = try? String(contentsOfFile: file.path, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let truncated = trimmed.count > maxChars
            return ExtractedContent(
                path: file.path,
                content: truncated ? String(trimmed.prefix(maxChars)) : trimmed,
                truncated: truncated
            )
        }
    }

    // PDFKit extraction — works without any external tools
    private static func extractPDFWithPDFKit(_ path: String) -> ExtractedContent? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
              let text = doc.string else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let truncated = trimmed.count > maxChars
        return ExtractedContent(
            path: path,
            content: truncated ? String(trimmed.prefix(maxChars)) : trimmed,
            truncated: truncated
        )
    }

    private static func shellExtract(cmd: String, path: String) async -> ExtractedContent? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-c", cmd]
                p.standardOutput = pipe
                p.standardError = Pipe()
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                p.environment = env
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { cont.resume(returning: nil); return }
                let truncated = trimmed.count > maxChars
                cont.resume(returning: ExtractedContent(
                    path: path,
                    content: truncated ? String(trimmed.prefix(maxChars)) : trimmed,
                    truncated: truncated
                ))
            }
        }
    }
}
