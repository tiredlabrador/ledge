import AppKit
import SwiftUI

// MARK: - Panel

/// Borderless, non-activating panel that floats above the desktop, never steals
/// focus, hides over full-screen apps, and can be dragged by its background.
final class FloatPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the SwiftUI glass draws its own
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = true // drag the pill anywhere but its controls
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = PlayerModel()
    private var panel: FloatPanel!
    private var visible = false
    private var activity: NSObjectProtocol?

    // Keep in sync with WidgetView.glassW / glassH / margin.
    private static let glassW: CGFloat = 270
    private static let glassH: CGFloat = 60
    private static let margin: CGFloat = 16
    private static var windowSize: NSSize {
        NSSize(width: glassW + margin * 2, height: glassH + margin * 2)
    }
    private static let positionsKey = "LedgePositions" // [displayID: [x, y]] window origins

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep polling timers accurate even while the window is invisible (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Now-playing polling"
        )

        let p = FloatPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize))
        p.contentView = NSHostingView(rootView: WidgetView(model: model))
        p.delegate = self
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        panel = p

        reposition()
        p.orderFrontRegardless()

        model.onResetPosition = { [weak self] in self?.resetPosition() }
        model.onUpdate = { [weak self] in self?.sync() }
        model.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reposition() }
    }

    /// Fade the panel in/out to match whether music is (recently) playing.
    private func sync() {
        let should = model.shouldShow
        guard should != visible else { return }
        visible = should
        model.visible = should
        panel.ignoresMouseEvents = !should // an invisible window must not eat clicks
        if should { reposition() } // place it correctly as it appears
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = should ? 0.45 : 0.9
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = should ? 1 : 0
        }
    }

    // MARK: - Positioning

    /// Move the panel to its remembered spot on the current dock screen, or, if it
    /// has never been placed there, to a sensible default just above the dock.
    private func reposition() {
        guard let screen = dockScreen() else { return }
        let f = screen.frame
        let dockBand = screen.visibleFrame.minY - screen.frame.minY

        var origin: NSPoint
        if let saved = savedOrigin(for: screen) {
            origin = saved
        } else {
            // Default: glass floats just above the dock band, near the left edge.
            let band = dockBand > 8 ? dockBand : 8
            let glassX = f.minX + 12
            let glassY = f.minY + band + 6
            origin = NSPoint(x: glassX - Self.margin, y: glassY - Self.margin)
        }

        var frame = NSRect(origin: origin, size: Self.windowSize)
        frame = clamp(frame, to: screen)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func resetPosition() {
        guard let screen = screenContaining(panel.frame) ?? dockScreen() else { return }
        var all = positions()
        all.removeValue(forKey: displayID(for: screen))
        UserDefaults.standard.set(all, forKey: Self.positionsKey)
        reposition()
    }

    /// Persist the panel's spot whenever the user finishes dragging it.
    func windowDidMove(_ notification: Notification) {
        guard let screen = screenContaining(panel.frame) else { return }
        var all = positions()
        let o = panel.frame.origin
        all[displayID(for: screen)] = [Double(o.x), Double(o.y)]
        UserDefaults.standard.set(all, forKey: Self.positionsKey)
    }

    // MARK: - Position storage / screen helpers

    private func positions() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: [Double]] ?? [:]
    }

    private func savedOrigin(for screen: NSScreen) -> NSPoint? {
        guard let xy = positions()[displayID(for: screen)], xy.count == 2 else { return nil }
        return NSPoint(x: xy[0], y: xy[1])
    }

    private func displayID(for screen: NSScreen) -> String {
        let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return num?.stringValue ?? "main"
    }

    /// Whichever screen currently hosts the dock (falls back to main / first).
    private func dockScreen() -> NSScreen? {
        for s in NSScreen.screens where s.visibleFrame.minY - s.frame.minY > 8 { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func screenContaining(_ frame: NSRect) -> NSScreen? {
        let c = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) }
    }

    /// Keep the whole window on-screen.
    private func clamp(_ frame: NSRect, to screen: NSScreen) -> NSRect {
        let v = screen.frame
        var r = frame
        r.origin.x = min(max(r.origin.x, v.minX), v.maxX - r.width)
        r.origin.y = min(max(r.origin.y, v.minY), v.maxY - r.height)
        return r
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
