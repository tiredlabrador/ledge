import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Panel

/// Borderless, non-activating panel that floats above the desktop but never
/// steals focus and never appears over full-screen apps (just like the dock hides).
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
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = PlayerModel()
    private var panel: FloatPanel!
    private var visible = false
    private var activity: NSObjectProtocol?
    private var promptedAX = false

    // Keep in sync with WidgetView.glassW / glassH / margin.
    private static let glassW: CGFloat = 270
    private static let glassH: CGFloat = 60
    private static let margin: CGFloat = 16
    private static var windowSize: NSSize {
        NSSize(width: glassW + margin * 2, height: glassH + margin * 2)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep polling timers accurate even while the window is invisible (no App Nap).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Now-playing polling"
        )

        let p = FloatPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize))
        p.contentView = NSHostingView(rootView: WidgetView(model: model))
        p.alphaValue = 0
        p.ignoresMouseEvents = true
        panel = p

        reposition()
        p.orderFrontRegardless()

        // Prompt for Accessibility only when the user opts into snapping (never
        // nags on launch), so it can read the dock's position for the tucked look.
        model.onRequestAX = { [weak self] in self?.promptAXOnce() }
        model.onUpdate = { [weak self] in self?.sync() }
        model.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.reposition() }
    }

    /// Fade the panel in/out to match whether music is (recently) playing.
    private func sync() {
        reposition()
        let should = model.shouldShow
        guard should != visible else { return }
        visible = should
        model.visible = should
        panel.ignoresMouseEvents = !should // an invisible window must not eat clicks
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = should ? 0.45 : 0.9
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = should ? 1 : 0
        }
    }

    // MARK: - Positioning

    /// Position the glass. When snapping is on and Accessibility is granted, tuck
    /// it flush against the dock's left edge, matched to the dock's height. Otherwise
    /// sit in the bottom-left corner of whichever screen owns the dock.
    private func reposition() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        var target: NSScreen?
        var dockBand: CGFloat = 0
        for s in screens {
            let h = s.visibleFrame.minY - s.frame.minY
            if h > 8 { target = s; dockBand = h; break }
        }
        let screen = target ?? NSScreen.main ?? screens[0]
        let f = screen.frame

        let gW = Self.glassW, gH = Self.glassH
        let gap: CGFloat = 8
        var glass: NSRect

        let dock = model.snapToDock ? dockFrameCocoa() : nil
        if let dock, dock.width > dock.height, dock.minX >= gW + gap + 2 {
            // Room beside the (centred) dock: tuck flush against its left edge.
            glass = NSRect(x: dock.minX - gap - gW, y: dock.midY - gH / 2, width: gW, height: gH)
        } else if let dock, dock.width > dock.height {
            // Wide dock (e.g. a near-full-width laptop dock): float just above its
            // left end, so it never lands on top of the dock.
            glass = NSRect(x: max(f.minX + 8, dock.minX), y: dock.maxY + 6, width: gW, height: gH)
        } else {
            // No dock reading (Accessibility off): float just above the dock band
            // at the left edge. Safe on any screen — never collides with the dock.
            glass = NSRect(x: f.minX + 12, y: f.minY + dockBand + 6, width: gW, height: gH)
        }

        let frame = glass.insetBy(dx: -Self.margin, dy: -Self.margin)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The dock's on-screen glass rect in Cocoa (bottom-left origin) coordinates,
    /// or nil if Accessibility isn't granted or the dock can't be read.
    private func dockFrameCocoa() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }

        let appEl = AXUIElementCreateApplication(dock.processIdentifier)
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let children = kidsRef as? [AXUIElement] else { return nil }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            guard roleRef as? String == kAXListRole as String else { continue }

            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success
            else { return nil }

            var p = CGPoint.zero
            var s = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)

            // AX is top-left origin on the primary display; flip to Cocoa bottom-left.
            let primaryH = CGDisplayBounds(CGMainDisplayID()).height
            return NSRect(x: p.x, y: primaryH - p.y - s.height, width: s.width, height: s.height)
        }
        return nil
    }

    private func promptAXOnce() {
        guard !promptedAX, !AXIsProcessTrusted() else { return }
        promptedAX = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
