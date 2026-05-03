import AppKit

struct FileContext: Identifiable, Hashable {
    let id = UUID()
    let path: String
    var size: Int64? = nil
    var fileKind: String? = nil
    var extraMeta: String? = nil

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var ext: String  { URL(fileURLWithPath: path).pathExtension.lowercased() }

    var isDirectory: Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    var humanSize: String {
        guard let sz = size else { return "" }
        return ByteCountFormatter.string(fromByteCount: sz, countStyle: .file)
    }

    // One-line description injected into the LLM context
    var contextLine: String {
        var parts: [String] = []
        if let kind = fileKind { parts.append(kind) }
        if !humanSize.isEmpty  { parts.append(humanSize) }
        if let m = extraMeta   { parts.append(m) }
        let suffix = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return "\(name)\(suffix)"
    }

    var icon: String {
        switch ext {
        case "mp4","mov","avi","mkv","webm":            return "film"
        case "mp3","wav","aac","flac","m4a":            return "music.note"
        case "jpg","jpeg","png","gif","webp","heic","tiff": return "photo"
        case "pdf":                                     return "doc.richtext"
        case "zip","tar","gz","bz2","7z","rar":         return "archivebox"
        case "py","js","ts","swift","go","rs","c","cpp","h": return "chevron.left.forwardslash.chevron.right"
        case "txt","md","rtf","doc","docx":             return "doc.text"
        case "sh","bash","zsh":                         return "terminal"
        default: return isDirectory ? "folder" : "doc"
        }
    }
}

class FinderService {
    static let shared = FinderService()
    private init() {}

    func getSelectedFiles() -> [FileContext] {
        let script = """
        tell application "Finder"
            try
                set selectedItems to selection as alias list
                set paths to {}
                repeat with anItem in selectedItems
                    set end of paths to POSIX path of anItem
                end repeat
                return paths
            on error
                return {}
            end try
        end tell
        """
        return runAppleScript(script)
            .components(separatedBy: "\n")
            .map  { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map  { path -> FileContext in
                var ctx = FileContext(path: path)
                let info = FileInspector.inspect(path)
                ctx.size      = info.size
                ctx.fileKind  = info.kind
                ctx.extraMeta = info.extraMeta
                return ctx
            }
    }

    func getCurrentDirectory() -> String? {
        let script = """
        tell application "Finder"
            try
                set frontWindow to front window
                set targetFolder to target of frontWindow as alias
                return POSIX path of targetFolder
            on error
                return missing value
            end try
        end tell
        """
        let result = runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    func getFinderWindowFrame() -> NSRect? {
        let script = """
        tell application "Finder"
            try
                set frontWindow to front window
                set b to bounds of frontWindow
                return (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
            on error
                return missing value
            end try
        end tell
        """
        let result = runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = result.components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let screen = NSScreen.main else { return nil }
        let screenHeight = screen.frame.height
        let x = parts[0], top = parts[1], right = parts[2], bottom = parts[3]
        let width = right - x
        let height = bottom - top
        let nsY = screenHeight - bottom
        return NSRect(x: x, y: nsY, width: width, height: height)
    }

    private func runAppleScript(_ source: String) -> String {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "" }
        let result = script.executeAndReturnError(&error)
        if error != nil { return "" }
        return result.stringValue ?? ""
    }
}
