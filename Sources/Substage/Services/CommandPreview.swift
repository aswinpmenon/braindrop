import Foundation

enum FileEffect: Identifiable {
    case created(String)
    case modified(String)
    case deleted(String)
    case moved(from: String, to: String)
    case read(String)

    var id: String {
        switch self {
        case .created(let p): return "create:\(p)"
        case .modified(let p): return "modify:\(p)"
        case .deleted(let p): return "delete:\(p)"
        case .moved(let f, let t): return "move:\(f):\(t)"
        case .read(let p): return "read:\(p)"
        }
    }

    var label: String {
        switch self {
        case .created(let p): return URL(fileURLWithPath: p).lastPathComponent
        case .modified(let p): return URL(fileURLWithPath: p).lastPathComponent
        case .deleted(let p): return URL(fileURLWithPath: p).lastPathComponent
        case .moved(_, let t): return URL(fileURLWithPath: t).lastPathComponent
        case .read(let p): return URL(fileURLWithPath: p).lastPathComponent
        }
    }

    var verb: String {
        switch self {
        case .created: return "Create"
        case .modified: return "Modify"
        case .deleted: return "Delete"
        case .moved: return "Move"
        case .read: return "Read"
        }
    }

    var symbol: String {
        switch self {
        case .created: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .moved: return "arrow.right.circle.fill"
        case .read: return "eye.circle.fill"
        }
    }

    var colorName: String {
        switch self {
        case .created: return "green"
        case .modified: return "orange"
        case .deleted: return "red"
        case .moved: return "blue"
        case .read: return "secondary"
        }
    }
}

enum CommandCategory {
    case readOnly
    case fileCreation
    case fileDeletion
    case systemModification
    case unknown

    var label: String {
        switch self {
        case .readOnly: return "Read-only"
        case .fileCreation: return "File creation"
        case .fileDeletion: return "File deletion"
        case .systemModification: return "System modification"
        case .unknown: return "Command"
        }
    }
}

struct PreviewResult {
    var effects: [FileEffect] = []
    var warnings: [String] = []
    var category: CommandCategory = .unknown
    var isDestructive: Bool { effects.contains { if case .deleted = $0 { return true }; return false } }
}

class CommandPreview {
    static let shared = CommandPreview()
    private init() {}

    func analyze(command: String, context: [FileContext]) -> PreviewResult {
        var result = PreviewResult()
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = tokenize(cmd)
        guard !tokens.isEmpty else { return result }

        let baseCmd = URL(fileURLWithPath: tokens[0]).lastPathComponent

        switch baseCmd {
        case "rm":
            result.category = .fileDeletion
            let paths = extractNonFlagArgs(tokens)
            let hasRecursive = tokens.contains("-r") || tokens.contains("-rf") || tokens.contains("-fr")
            for path in paths {
                result.effects.append(.deleted(path))
            }
            if hasRecursive { result.warnings.append("Recursive deletion — all contents removed") }
            if tokens.contains("-f") || tokens.contains("-rf") { result.warnings.append("Force deletion — no confirmation") }

        case "mv":
            result.category = .fileCreation
            let paths = extractNonFlagArgs(tokens)
            if paths.count >= 2 {
                let dest = paths.last!
                for src in paths.dropLast() {
                    result.effects.append(.moved(from: src, to: dest + "/" + URL(fileURLWithPath: src).lastPathComponent))
                }
            }

        case "cp":
            result.category = .fileCreation
            let paths = extractNonFlagArgs(tokens)
            if paths.count >= 2 {
                let dest = paths.last!
                for src in paths.dropLast() {
                    let name = URL(fileURLWithPath: src).lastPathComponent
                    result.effects.append(.read(src))
                    result.effects.append(.created(dest + "/" + name))
                }
            }

        case "mkdir":
            result.category = .fileCreation
            for path in extractNonFlagArgs(tokens) {
                result.effects.append(.created(path))
            }

        case "touch":
            result.category = .fileCreation
            for path in extractNonFlagArgs(tokens) {
                result.effects.append(.created(path))
            }

        case "ffmpeg":
            result.category = .fileCreation
            let output = extractFfmpegOutput(tokens)
            let input = extractFfmpegInput(tokens)
            if let i = input { result.effects.append(.read(i)) }
            if let o = output { result.effects.append(.created(o)) }

        case "convert", "magick":
            result.category = .fileCreation
            let paths = extractNonFlagArgs(tokens)
            if let first = paths.first { result.effects.append(.read(first)) }
            if let last = paths.last, paths.count > 1 { result.effects.append(.created(last)) }

        case "sips":
            result.category = .fileCreation
            let paths = extractNonFlagArgs(tokens)
            if let outIdx = tokens.firstIndex(of: "--out"), outIdx + 1 < tokens.count {
                result.effects.append(.created(tokens[outIdx + 1]))
                paths.forEach { result.effects.append(.read($0)) }
            } else {
                paths.forEach { result.effects.append(.modified($0)) }
                result.warnings.append("sips modifies files in place by default")
            }

        case "zip":
            result.category = .fileCreation
            let paths = extractNonFlagArgs(tokens)
            if let archive = paths.first { result.effects.append(.created(archive)) }
            paths.dropFirst().forEach { result.effects.append(.read($0)) }

        case "unzip":
            result.category = .fileCreation
            let paths = extractNonFlagArgs(tokens)
            if let archive = paths.first { result.effects.append(.read(archive)) }

        case "cat", "head", "tail", "less", "wc", "grep", "find", "ls", "du", "file", "exiftool", "mdls":
            result.category = .readOnly
            for path in extractNonFlagArgs(tokens) {
                result.effects.append(.read(path))
            }

        case "echo", "printf":
            let hasRedirect = cmd.contains(">")
            result.category = hasRedirect ? .fileCreation : .readOnly
            if hasRedirect {
                if let outPath = extractRedirectOutput(cmd) {
                    if cmd.contains(">>") {
                        result.effects.append(.modified(outPath))
                    } else {
                        result.effects.append(.created(outPath))
                    }
                }
            }

        case "python3", "python", "node", "ruby", "perl":
            result.category = .unknown
            result.warnings.append("Script execution — effects depend on script content")

        case "brew":
            result.category = .systemModification
            result.warnings.append("Package manager operation")

        case "open":
            result.category = .readOnly
            for path in extractNonFlagArgs(tokens) {
                result.effects.append(.read(path))
            }

        case "bc", "date", "uname", "sw_vers", "system_profiler":
            result.category = .readOnly

        default:
            result.category = .unknown
            if cmd.contains(">") {
                result.category = .fileCreation
                if let outPath = extractRedirectOutput(cmd) {
                    result.effects.append(cmd.contains(">>") ? .modified(outPath) : .created(outPath))
                }
            }
        }

        // Add context files as read if not already listed
        if result.effects.isEmpty && !context.isEmpty {
            result.category = .readOnly
            for f in context { result.effects.append(.read(f.path)) }
        }

        return result
    }

    private func tokenize(_ cmd: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character? = nil

        for char in cmd {
            if let q = inQuote {
                if char == q { inQuote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                inQuote = char
            } else if char == " " || char == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func extractNonFlagArgs(_ tokens: [String]) -> [String] {
        tokens.dropFirst().filter { !$0.hasPrefix("-") && ($0.hasPrefix("/") || $0.contains(".") || $0.hasPrefix("~")) }
    }

    private func extractFfmpegInput(_ tokens: [String]) -> String? {
        guard let idx = tokens.firstIndex(of: "-i"), idx + 1 < tokens.count else { return nil }
        return tokens[idx + 1]
    }

    private func extractFfmpegOutput(_ tokens: [String]) -> String? {
        let flags = ["-i", "-vcodec", "-acodec", "-c", "-b:v", "-b:a", "-vf", "-af", "-r", "-s", "-t", "-ss", "-to", "-map", "-f"]
        var skipNext = false
        var lastNonFlag: String? = nil
        for (i, token) in tokens.enumerated() {
            if i == 0 { continue }
            if skipNext { skipNext = false; continue }
            if flags.contains(token) { skipNext = true; continue }
            if token.hasPrefix("-") { continue }
            lastNonFlag = token
        }
        return lastNonFlag
    }

    private func extractRedirectOutput(_ cmd: String) -> String? {
        let pattern = #">>?\s*([^\s;|&]+)"#
        guard let range = cmd.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(cmd[range])
        return match.replacingOccurrences(of: ">>", with: "").replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
    }
}

