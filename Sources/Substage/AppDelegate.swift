import AppKit
import SwiftUI
import Combine

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var panel: SubstagePanel?
    private var settingsWindow: NSWindow?
    private var viewModel: CommandBarViewModel?
    private var trackingTimer: Timer?
    private var heightCancellable: AnyCancellable?
    private var lastFinderFrame: NSRect?

    private let hotkeyManager = HotkeyManager.shared
    private let settings      = AppSettings.shared
    private let finderService = FinderService.shared

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBarItem()
        setupPanel()
        hotkeyManager.onHotkey = { [weak self] in self?.togglePanel() }
        hotkeyManager.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeyChanged),
            name: .hotkeyChanged, object: nil)
    }

    // MARK: - Status bar

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let btn = statusItem?.button else { return }
        btn.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Substage")
        btn.image?.isTemplate = true
        btn.action = #selector(statusBarClicked)
        btn.target  = self
    }

    @objc private func statusBarClicked() {
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Substage", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let sett = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        sett.target = self
        menu.addItem(sett)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Substage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

        let p = SubstagePanel()
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
        vm.onAppear()
        let ff = finderService.getFinderWindowFrame()
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
        win.title     = "Substage"
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
