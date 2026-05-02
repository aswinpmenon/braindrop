import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// main.swift always runs on the main thread — safe to assume MainActor isolation
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
