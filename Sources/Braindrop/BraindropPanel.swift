import AppKit

class BraindropPanel: NSPanel {

    static let minWidth:    CGFloat = 480
    static let maxWidth:    CGFloat = 1400
    static let barRowHeight: CGFloat = 44
    static let defaultWidth: CGFloat = 680

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BraindropPanel.defaultWidth, height: BraindropPanel.barRowHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel             = true
        level                       = .floating
        isMovableByWindowBackground = true   // drag from any non-interactive area
        isMovable                   = true
        hidesOnDeactivate           = false
        isReleasedWhenClosed        = false
        isOpaque                    = false
        backgroundColor             = .clear
        hasShadow                   = true
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // MARK: - Position

    /// Place panel.
    /// • If a Finder window is visible: dock just below it, matching its width.
    /// • Otherwise: bottom-centre of screen, just above the Dock.
    func reposition(finderFrame: NSRect?, contentHeight: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let sv = screen.visibleFrame   // already excludes the Dock & menu bar

        let w: CGFloat
        let x: CGFloat
        let y: CGFloat

        if let f = finderFrame, f.width > 0 {
            // Match Finder window width, clamp to our min/max
            let rawW = max(BraindropPanel.minWidth, min(f.width, BraindropPanel.maxWidth))
            w = rawW
            x = max(sv.minX, min(f.minX, sv.maxX - rawW))
            // Sit directly below the Finder window; clamp so it never hides below dock
            y = max(sv.minY, f.minY - contentHeight)
        } else {
            // No Finder window: centre horizontally, sit just above the Dock
            w = BraindropPanel.defaultWidth
            x = sv.midX - w / 2
            y = sv.minY   // visibleFrame.minY == top of Dock
        }

        setFrame(NSRect(x: x, y: y, width: w, height: contentHeight), display: false)
    }

    // MARK: - Animate height

    /// Keep the top edge fixed while animating to a new height.
    func animateHeight(_ newHeight: CGFloat) {
        let current = frame
        let newY     = current.maxY - newHeight
        let newFrame = NSRect(x: current.minX, y: newY, width: current.width, height: newHeight)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(newFrame, display: true)
        }
    }

    override var canBecomeKey:  Bool { true  }
    override var canBecomeMain: Bool { false }
}
