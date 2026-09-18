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
        isMovableByWindowBackground = false // we move the window ourselves (no magnetism)
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Don't let AppKit pull the window back inside the screen while dragging —
    /// this is what caused the "sticking at the edges" feel. Fully free placement.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = PlayerModel()
    private var panel: FloatPanel!
    private var visible = false
    private var activity: NSObjectProtocol?
    private var seeThrough = false
    private var seeThroughTimer: Timer?

    // Keep in sync with WidgetView.glassW / glassH / margin.
    private static let glassW: CGFloat = 270
    private static let glassH: CGFloat = 60
    private static let margin: CGFloat = 16
    private static var windowSize: NSSize {
        NSSize(width: glassW + margin * 2, height: glassH + margin * 2)
    }
    private static let positionsKey = "LedgePositions" // [displayID: [x, y]] current spot
    private static let defaultsKey = "LedgeDefaults"   // [displayID: [x, y]] user's home spot

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep polling timers accurate even while the window is invisible (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Now-playing polling"
        )

        let p = FloatPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize))
        p.contentView = NSHostingView(rootView: WidgetView(model: model, ui: WidgetUIState()))
        p.delegate = self
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        panel = p

        reposition()
        p.orderFrontRegardless()

        model.onSetDefault = { [weak self] in self?.setDefaultPosition() }
        model.onResetPosition = { [weak self] in self?.resetPosition() }
        model.currentWindowOrigin = { [weak self] in self?.panel.frame.origin ?? .zero }
        model.onMoveWindowTo = { [weak self] p in self?.panel.setFrameOrigin(p) }
        model.isMouseOverWidget = { [weak self] in
            guard let self else { return false }
            return self.glassRect.contains(NSEvent.mouseLocation)
        }
        model.onUpdate = { [weak self] in self?.sync() }
        model.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reposition() }
    }

    /// Fade the panel in/out to match whether music is (recently) playing.
    private func sync() {
        updateSeeThroughTimer()
        let should = model.shouldShow
        guard should != visible else { return }
        visible = should
        model.visible = should
        if should { reposition() } // place it correctly as it appears
        updateSeeThroughTimer()
        applyAppearance(duration: should ? 0.45 : 0.9)
    }

    /// One place decides opacity and click-through, from visibility + see-through.
    private func applyAppearance(duration: Double) {
        // An invisible or ghosted window must never eat clicks meant for what's behind.
        panel.ignoresMouseEvents = !visible || seeThrough
        let target: CGFloat = !visible ? 0 : (seeThrough ? 0.12 : 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = target
        }
    }

    // MARK: - See-through (tap Option over the widget)

    /// The visible glass pill, excluding the transparent shadow margin.
    private var glassRect: NSRect {
        panel.frame.insetBy(dx: Self.margin, dy: Self.margin)
    }

    /// Watch the Option key only while the widget is on screen. Reads the live
    /// modifier state directly, so it needs no extra permissions.
    private func updateSeeThroughTimer() {
        if visible && model.seeThroughEnabled {
            guard seeThroughTimer == nil else { return }
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkSeeThrough() }
            RunLoop.main.add(t, forMode: .common)
            seeThroughTimer = t
        } else {
            seeThroughTimer?.invalidate()
            seeThroughTimer = nil
            if seeThrough { setSeeThrough(false) }
        }
    }

    /// Option over the widget → ghost it. It stays ghosted until the mouse leaves,
    /// so you can let go of Option and click behind it normally (an Option-click
    /// would mean something different in most apps).
    private func checkSeeThrough() {
        let over = glassRect.contains(NSEvent.mouseLocation)
        if !seeThrough {
            if over && NSEvent.modifierFlags.contains(.option) { setSeeThrough(true) }
        } else if !over {
            setSeeThrough(false)
        }
    }

    private func setSeeThrough(_ on: Bool) {
        seeThrough = on
        model.seeThrough = on
        applyAppearance(duration: on ? 0.12 : 0.25)
    }

    // MARK: - Positioning

    /// Move the panel to its remembered spot on the current dock screen, or, if it
    /// has never been placed there, to a sensible default just above the dock.
    private func reposition() {
        guard let screen = dockScreen() else { return }

        // Prefer exactly where it was last left; else the user's saved default;
        // else the built-in bottom-left home.
        let origin: NSPoint
        let saved = savedOrigin(for: screen)
        if let saved, isReasonablyVisible(NSRect(origin: saved, size: Self.windowSize)) {
            origin = saved
        } else {
            origin = defaultOrigin(for: screen) ?? homeOrigin(for: screen)
        }

        let frame = NSRect(origin: origin, size: Self.windowSize)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Save wherever the widget currently sits as this screen's default "home".
    private func setDefaultPosition() {
        guard let screen = screenContaining(panel.frame) ?? dockScreen() else { return }
        var all = defaults()
        let o = panel.frame.origin
        all[displayID(for: screen)] = [Double(o.x), Double(o.y)]
        UserDefaults.standard.set(all, forKey: Self.defaultsKey)
    }

    /// Jump back to the saved default home (or the built-in bottom-left one).
    private func resetPosition() {
        guard let screen = screenContaining(panel.frame) ?? dockScreen() else { return }
        let target = defaultOrigin(for: screen) ?? homeOrigin(for: screen)
        panel.setFrameOrigin(target) // windowDidMove persists this as the current spot
    }

    /// Built-in home: bottom-left, just above the dock band.
    private func homeOrigin(for screen: NSScreen) -> NSPoint {
        let f = screen.frame
        let band = screen.visibleFrame.minY - screen.frame.minY
        let b = band > 8 ? band : 8
        return NSPoint(x: f.minX + 12 - Self.margin, y: f.minY + b + 6 - Self.margin)
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

    private func defaults() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: [Double]] ?? [:]
    }

    private func defaultOrigin(for screen: NSScreen) -> NSPoint? {
        guard let xy = defaults()[displayID(for: screen)], xy.count == 2 else { return nil }
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
            ?? NSScreen.screens.max { a, b in
                a.frame.intersection(frame).area < b.frame.intersection(frame).area
            }
    }

    /// True if enough of the widget lands on some screen that it isn't lost —
    /// used only to fall back to the default if a saved spot is now off-screen
    /// (e.g. a display was unplugged), never to reposition an otherwise-fine spot.
    private func isReasonablyVisible(_ frame: NSRect) -> Bool {
        for s in NSScreen.screens {
            let i = s.frame.intersection(frame)
            if i.width > 60, i.height > 40 { return true }
        }
        return false
    }
}

private extension NSRect {
    var area: CGFloat { width * height }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
