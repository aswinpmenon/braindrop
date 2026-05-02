import AppKit

class BraindropPanel: NSPanel {

    static let minWidth: CGFloat  = 480
    static let maxWidth: CGFloat  = 1400
    static let barRowHeight: CGFloat = 44

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: BraindropPanel.barRowHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel          = true
        level                    = .floating
        isMovableByWindowBackground = false
        hidesOnDeactivate        = false
        isReleasedWhenClosed     = false
        isOpaque                 = false
        backgroundColor          = .clear
        hasShadow                = true
        collectionBehavior       = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Position the panel immediately below `finderFrame`, matching its width.
    // `contentHeight` is the current SwiftUI view's ideal height.
    func reposition(finderFrame: NSRect?, contentHeight: CGFloat) {
        guard let screen = NSScreen.main else { return }
        let sv = screen.visibleFrame

        let rawW: CGFloat
        let rawX: CGFloat

        if let f = finderFrame {
            rawW = f.width
            rawX = f.minX
        } else {
            rawW = 600
            rawX = sv.midX - 300
        }

        let w = max(BraindropPanel.minWidth, min(rawW, BraindropPanel.maxWidth))
        let x = max(sv.minX, min(rawX, sv.maxX - w))

        let y: CGFloat
        if let f = finderFrame {
            y = f.minY - contentHeight        // directly below Finder
        } else {
            y = sv.midY + 40
        }

        let clampedY = max(sv.minY, y)
        setFrame(NSRect(x: x, y: clampedY, width: w, height: contentHeight), display: false)
    }

    // Animate to a new height while keeping the top edge fixed.
    func animateHeight(_ newHeight: CGFloat) {
        let current = frame
        let newY     = current.maxY - newHeight        // keep top edge pinned
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
