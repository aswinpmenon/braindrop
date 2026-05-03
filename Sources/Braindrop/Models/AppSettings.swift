import AppKit
import Carbon.HIToolbox

class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: Server
    @Published var ollamaBaseURL: String {
        didSet { save("ollamaBaseURL", ollamaBaseURL) }
    }
    @Published var ollamaModel: String {
        didSet { save("ollamaModel", ollamaModel) }
    }

    // MARK: Hotkey
    @Published var hotkeyKeyCode: UInt32 {
        didSet { save("hotkeyKeyCode", Int(hotkeyKeyCode)) }
    }
    @Published var hotkeyModifiers: UInt32 {
        didSet { save("hotkeyModifiers", Int(hotkeyModifiers)) }
    }

    // MARK: Auto-run categories
    @Published var autoRunReadOnly: Bool          { didSet { save("autoRunReadOnly", autoRunReadOnly) } }
    @Published var autoRunFileCreation: Bool      { didSet { save("autoRunFileCreation", autoRunFileCreation) } }
    @Published var autoRunRename: Bool            { didSet { save("autoRunRename", autoRunRename) } }
    @Published var autoRunMove: Bool              { didSet { save("autoRunMove", autoRunMove) } }
    @Published var autoRunModify: Bool            { didSet { save("autoRunModify", autoRunModify) } }
    @Published var autoRunOutsideFolder: Bool     { didSet { save("autoRunOutsideFolder", autoRunOutsideFolder) } }
    @Published var autoRunMinorSideEffects: Bool  { didSet { save("autoRunMinorSideEffects", autoRunMinorSideEffects) } }
    @Published var autoRunSignificantSideEffects: Bool { didSet { save("autoRunSignificantSideEffects", autoRunSignificantSideEffects) } }
    @Published var autoRunMoveToTrash: Bool       { didSet { save("autoRunMoveToTrash", autoRunMoveToTrash) } }
    @Published var autoRunFileDeletion: Bool      { didSet { save("autoRunFileDeletion", autoRunFileDeletion) } }
    @Published var autoRunSystemModification: Bool { didSet { save("autoRunSystemModification", autoRunSystemModification) } }
    @Published var autoRunCommandsWithErrors: Bool { didSet { save("autoRunCommandsWithErrors", autoRunCommandsWithErrors) } }

    var hotkeyDisplayString: String {
        var p: [String] = []
        if hotkeyModifiers & UInt32(cmdKey)     != 0 { p.append("⌘") }
        if hotkeyModifiers & UInt32(controlKey) != 0 { p.append("⌃") }
        if hotkeyModifiers & UInt32(optionKey)  != 0 { p.append("⌥") }
        if hotkeyModifiers & UInt32(shiftKey)   != 0 { p.append("⇧") }
        p.append(keyName(hotkeyKeyCode))
        return p.joined()
    }

    private func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space:  return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab:    return "⇥"
        default:
            let map: [Int: String] = [
                kVK_ANSI_A:"A", kVK_ANSI_B:"B", kVK_ANSI_C:"C", kVK_ANSI_D:"D",
                kVK_ANSI_E:"E", kVK_ANSI_F:"F", kVK_ANSI_G:"G", kVK_ANSI_H:"H",
                kVK_ANSI_I:"I", kVK_ANSI_J:"J", kVK_ANSI_K:"K", kVK_ANSI_L:"L",
                kVK_ANSI_M:"M", kVK_ANSI_N:"N", kVK_ANSI_O:"O", kVK_ANSI_P:"P",
                kVK_ANSI_Q:"Q", kVK_ANSI_R:"R", kVK_ANSI_S:"S", kVK_ANSI_T:"T",
                kVK_ANSI_U:"U", kVK_ANSI_V:"V", kVK_ANSI_W:"W", kVK_ANSI_X:"X",
                kVK_ANSI_Y:"Y", kVK_ANSI_Z:"Z"
            ]
            return map[Int(code)] ?? "Key(\(code))"
        }
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func bool(_ key: String, _ def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? def
    }

    private init() {
        ollamaBaseURL  = UserDefaults.standard.string(forKey: "ollamaBaseURL") ?? "http://127.0.0.1:8080"
        ollamaModel    = UserDefaults.standard.string(forKey: "ollamaModel")   ?? "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"

        let kc = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        hotkeyKeyCode  = kc == 0 ? UInt32(kVK_Space) : UInt32(kc)
        let hm = UserDefaults.standard.integer(forKey: "hotkeyModifiers")
        hotkeyModifiers = hm == 0 ? UInt32(controlKey) : UInt32(hm)

        let ud = UserDefaults.standard
        func b(_ key: String, _ def: Bool) -> Bool { ud.object(forKey: key) as? Bool ?? def }
        autoRunReadOnly               = b("autoRunReadOnly",               true)
        autoRunFileCreation           = b("autoRunFileCreation",           true)
        autoRunRename                 = b("autoRunRename",                 false)
        autoRunMove                   = b("autoRunMove",                   false)
        autoRunModify                 = b("autoRunModify",                 false)
        autoRunOutsideFolder          = b("autoRunOutsideFolder",          false)
        autoRunMinorSideEffects       = b("autoRunMinorSideEffects",       true)
        autoRunSignificantSideEffects = b("autoRunSignificantSideEffects", false)
        autoRunMoveToTrash            = b("autoRunMoveToTrash",            false)
        autoRunFileDeletion           = b("autoRunFileDeletion",           false)
        autoRunSystemModification     = b("autoRunSystemModification",     false)
        autoRunCommandsWithErrors     = b("autoRunCommandsWithErrors",     false)
    }
}
