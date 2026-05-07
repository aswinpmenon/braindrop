import Foundation

class ToolAvailability {
    static let shared = ToolAvailability()
    private(set) var checked = false
    private(set) var available: Set<String> = []
    private init() {}

    // tool binary → brew install command (casks use --cask flag)
    static let installCommands: [String: String] = [
        "pdftotext":   "brew install poppler",
        "pdfinfo":     "brew install poppler",
        "pdfseparate": "brew install poppler",
        "pdfunite":    "brew install poppler",
        "ffmpeg":      "brew install ffmpeg",
        "ffprobe":     "brew install ffmpeg",
        "pandoc":      "brew install pandoc",
        "gs":          "brew install ghostscript",
        "exiftool":    "brew install exiftool",
        "convert":     "brew install imagemagick",
        "magick":      "brew install imagemagick",
        "tesseract":   "brew install tesseract",
        "yt-dlp":      "brew install yt-dlp",
        "7z":          "brew install p7zip",
        "rclone":      "brew install rclone",
        "libreoffice": "brew install --cask libreoffice",
        "soffice":     "brew install --cask libreoffice",
        "handbrake":   "brew install --cask handbrake",
        "wget":        "brew install wget",
        "imagemagick": "brew install imagemagick",
    ]

    private let searchPaths = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    func checkAll() {
        let env = ["PATH": searchPaths]
        let tools = Array(ToolAvailability.installCommands.keys) + ["brew", "python3", "node", "ruby"]
        for tool in tools where which(tool, env: env) { available.insert(tool) }
        checked = true
    }

    func has(_ tool: String) -> Bool { available.contains(tool) }

    func markAvailable(_ tool: String) { available.insert(tool) }

    /// Mark all tools provided by a package as available.
    func markPackageInstalled(_ brewCmd: String) {
        for (tool, cmd) in ToolAvailability.installCommands where cmd == brewCmd {
            available.insert(tool)
        }
    }

    /// Returns the brew install command for a missing tool, or nil if unknown.
    func installCommand(for tool: String) -> String? {
        ToolAvailability.installCommands[tool]
    }

    /// Parse "command not found: X" from zsh stderr.
    static func missingTool(from errorText: String) -> String? {
        let pattern = #"command not found: (\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: errorText, range: NSRange(errorText.startIndex..., in: errorText)),
              let r = Range(m.range(at: 1), in: errorText) else { return nil }
        return String(errorText[r])
    }

    /// Parse `echo 'Install: brew install X'` that the LLM might emit as fallback.
    static func parseInstallEcho(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("echo") else { return nil }
        let pattern = #"brew install [^\'"]+?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let r = Range(m.range, in: trimmed) else { return nil }
        return String(trimmed[r])
    }

    func promptSummary() -> String {
        guard checked else { return "" }
        let tracked = ["pdftotext","ffmpeg","pandoc","gs","exiftool","libreoffice","soffice","tesseract"]
        let have    = tracked.filter { available.contains($0) }
        let missing = tracked.filter { !available.contains($0) }
        var parts: [String] = ["Always: sips textutil afconvert zip tar mdls wc open osascript"]
        if !have.isEmpty    { parts.append("Also installed: \(have.joined(separator: " "))") }
        if !missing.isEmpty { parts.append("Not yet installed: \(missing.joined(separator: " "))") }
        return parts.joined(separator: " | ")
    }

    private func which(_ tool: String, env: [String: String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [tool]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        p.environment = env
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
