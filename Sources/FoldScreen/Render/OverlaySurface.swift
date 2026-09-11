import AppKit

/// The full-screen panel the folded desktop is drawn into.
///
/// The panel sits above the menu bar on purpose. The capture includes the menu
/// bar, so if the overlay sat below it the real menu bar would stay pinned and
/// sharp on top of the fold, which breaks the illusion immediately. It never
/// takes focus and ignores the mouse: while the effect is up the user is closing
/// the lid, not clicking.
@MainActor
final class OverlaySurface {

    private var panel: NSPanel?
    private(set) var isVisible = false

    /// Creates the panel for a screen and puts it in front of everything.
    ///
    /// - Parameter contentView: the Metal view that draws the folded desktop.
    func present(contentView: NSView, on screen: NSScreen) {
        dismiss()
        let panel = OverlayPanel(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]
        panel.contentView = contentView
        panel.setFrame(screen.frame, display: true)
        self.panel = panel
        show()
    }

    /// Brings the panel forward without rebuilding it.
    func show() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Pushes the panel behind everything but keeps it alive, so the next fold
    /// does not have to allocate a window and a Metal view again.
    func conceal() {
        guard let panel else { return }
        panel.orderOut(nil)
        isVisible = false
    }

    /// Tears the panel down entirely.
    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        isVisible = false
    }
}

/// A panel that can never become key or main, so showing it never pulls focus
/// away from whatever the user was doing.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
