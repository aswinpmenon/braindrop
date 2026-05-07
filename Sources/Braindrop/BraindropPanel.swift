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

    /// Initial placement when the panel first appears.
    func reposition(finderFrame: NSRect?, contentHeight: CGFloat) {
        let target = targetFrame(finderFrame: finderFrame, contentHeight: contentHeight)
        setFrame(target, display: false)
    }

    /// Called at 50 ms intervals to magnetically follow the Finder window.
    /// Uses instant setFrameOrigin (no animation) so motion feels native.
    func magnetReposition(finderFrame: NSRect?, contentHeight: CGFloat) {
        let target = targetFrame(finderFrame: finderFrame, contentHeight: contentHeight)
        // Only update position/size if they actually changed to avoid redundant compositing
        if abs(target.minX - frame.minX) > 0.5 ||
           abs(target.minY - frame.minY) > 0.5 ||
           abs(target.width - frame.width) > 0.5 {
            setFrame(target, display: true)
        }
    }

    /// Compute where the panel should sit.
    /// • Finder window visible → dock flush below it, match its width.
    /// • No Finder window      → bottom-centre of screen, just above the Dock.
    private func targetFrame(finderFrame: NSRect?, contentHeight: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else { return frame }
        let sv = screen.visibleFrame   // excludes Dock & menu bar

        if let f = finderFrame, f.width > 50 {
            let w = max(BraindropPanel.minWidth, min(f.width, BraindropPanel.maxWidth))
            let x = max(sv.minX, min(f.minX, sv.maxX - w))
            let y = max(sv.minY, f.minY - contentHeight)   // flush below window
            return NSRect(x: x, y: y, width: w, height: contentHeight)
        } else {
            let w = BraindropPanel.defaultWidth
            let x = sv.midX - w / 2
            return NSRect(x: x, y: sv.minY, width: w, height: contentHeight)
        }
    }

    // MARK: - Animate height

    /// Keep the top edge fixed while animating to a new content height.
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
