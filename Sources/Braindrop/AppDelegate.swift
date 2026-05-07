import AppKit
import SwiftUI
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var panel: BraindropPanel?
    private var settingsWindow: NSWindow?
    private var viewModel: CommandBarViewModel?
    private var trackingTimer: Timer?
    private var heightCancellable: AnyCancellable?
    private var lastFinderFrame: NSRect?

    private let hotkeyManager = HotkeyManager.shared
    private let settings      = AppSettings.shared
    private let finderService = FinderService.shared
    private let mlxManager    = MLXServerManager.shared
    private var mlxCancellable: AnyCancellable?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarItem()
        setupPanel()
        hotkeyManager.onHotkey = { [weak self] in self?.togglePanel() }
        hotkeyManager.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        // Detect installed tools in background so prompts can reflect availability
        DispatchQueue.global(qos: .utility).async { ToolAvailability.shared.checkAll() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeyChanged),
            name: .hotkeyChanged, object: nil)
        // Start the MLX server as an in-process child — no terminal window needed
        mlxManager.start()
        // Reflect server state in the menu-bar icon
        mlxCancellable = mlxManager.$state
            .sink { [weak self] state in
                DispatchQueue.main.async { self?.updateStatusIcon(for: state) }
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mlxManager.stop()
    }

    // MARK: - Status bar

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let btn = statusItem?.button else { return }
        btn.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Braindrop")
        btn.image?.isTemplate = true
        btn.action = #selector(statusBarClicked)
        btn.target  = self
    }

    /// Update the menu-bar icon to reflect MLX server state.
    private func updateStatusIcon(for state: MLXServerManager.ServerState) {
        guard let btn = statusItem?.button else { return }
        switch state {
        case .idle:
            btn.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Braindrop")
            btn.image?.isTemplate = true
            btn.toolTip = "Braindrop"
        case .starting:
            btn.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Braindrop – starting")
            btn.image?.isTemplate = true
            btn.toolTip = "Braindrop – starting MLX server…"
        case .running:
            btn.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Braindrop – ready")
            btn.image?.isTemplate = true
            btn.toolTip = "Braindrop – ready"
        case .failed(let msg):
            btn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Braindrop – error")
            btn.image?.isTemplate = true
            btn.toolTip = "Braindrop – \(msg)"
        }
    }

    @objc private func statusBarClicked() {
        let menu = NSMenu()

        // MLX server status (read synchronously — already on main thread via @objc)
        let srvState = mlxManager.state
        let serverStatusTitle: String
        switch srvState {
        case .idle:     serverStatusTitle = "MLX Server: idle"
        case .starting: serverStatusTitle = "MLX Server: starting…"
        case .running:  serverStatusTitle = "MLX Server: running ✓"
        case .failed(let msg): serverStatusTitle = "MLX Server: \(msg)"
        }
        let serverItem = NSMenuItem(title: serverStatusTitle, action: nil, keyEquivalent: "")
        serverItem.isEnabled = false
        menu.addItem(serverItem)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Braindrop", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let sett = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        sett.target = self
        menu.addItem(sett)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Braindrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Panel setup

    private func setupPanel() {
        let vm    = CommandBarViewModel()
        viewModel = vm

        vm.onClose        = { [weak self] in self?.hidePanel() }
        vm.onOpenSettings = { [weak self] in self?.openSettings() }

        let hostingView = NSHostingView(rootView: CommandBarView(viewModel: vm))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let p = BraindropPanel()
        panel = p
        p.contentView = hostingView

        // Resize panel whenever the view reports a new ideal height
        heightCancellable = vm.$idealHeight
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] h in self?.panel?.animateHeight(h) }
    }

    // MARK: - Show / hide

    @objc func showPanel() {
        guard let panel = panel, let vm = viewModel else { return }
        // Capture Finder context BEFORE panel takes focus — selection & folder are still live
        let files = finderService.getSelectedFiles()
        let cwd   = finderService.getCurrentDirectory()
        let ff    = finderService.getFinderWindowFrame()
        vm.onAppear(files: files, workingDir: cwd)
        lastFinderFrame = ff
        panel.reposition(finderFrame: ff, contentHeight: vm.idealHeight)
        panel.orderFrontRegardless()
        panel.makeKey()
        startTracking()
    }

    func hidePanel() {
        stopTracking()
        panel?.orderOut(nil)
        viewModel?.reset()
    }

    func togglePanel() {
        panel?.isVisible == true ? hidePanel() : showPanel()
    }

    // MARK: - Finder tracking

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePosition() }
        }
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func updatePosition() {
        guard let panel = panel, panel.isVisible, let vm = viewModel else { return }
        let ff = finderService.getFinderWindowFrame()
        guard ff != lastFinderFrame else { return }
        lastFinderFrame = ff
        panel.reposition(finderFrame: ff, contentHeight: vm.idealHeight)
    }

    // MARK: - Settings

    @objc func openSettings() {
        if let w = settingsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let ctrl = NSHostingController(rootView: SettingsView())
        let win  = NSWindow(contentViewController: ctrl)
        win.title     = "Braindrop"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 540, height: 480))
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }

    @objc private func hotkeyChanged() {
        hotkeyManager.unregister()
        hotkeyManager.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
}
