import AppKit
import Carbon.HIToolbox

private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    if hotKeyID.signature == braindropSignature && hotKeyID.id == 1 {
        DispatchQueue.main.async { HotkeyManager.shared.triggerHotkey() }
    }
    return noErr
}

private let braindropSignature: FourCharCode = {
    var result: FourCharCode = 0
    for char in "subS".utf16 { result = (result << 8) + FourCharCode(char) }
    return result
}()

class HotkeyManager {
    static let shared = HotkeyManager()
    var onHotkey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        var spec = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, nil, &eventHandlerRef)

        let id = EventHotKeyID(signature: braindropSignature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    func triggerHotkey() {
        onHotkey?()
    }
}
