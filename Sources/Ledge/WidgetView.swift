import AppKit
import SwiftUI

/// The player pill. At rest: artwork + title + artist, roomy and centred.
/// On hover: large playback controls take over the whole text area.
struct WidgetView: View {
    @ObservedObject var model: PlayerModel
    @State private var hovering = false
    @State private var dragAnchor: (mouse: CGPoint, origin: CGPoint)?

    // Keep in sync with AppDelegate.glassW / glassH / margin.
    static let glassW: CGFloat = 270
    static let glassH: CGFloat = 60
    static let margin: CGFloat = 16

    var body: some View {
        content
            .frame(width: Self.glassW, height: Self.glassH)
            .modifier(GlassBackground())
            .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
            .scaleEffect(model.visible ? 1 : 0.96, anchor: .center)
            .offset(y: model.visible ? 0 : 4)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: model.visible)
            .onHover { h in
                withAnimation(.smooth(duration: 0.2)) { hovering = h }
                model.hovering = h
            }
            .contentShape(Rectangle()) // whole pill is grabbable, not just the art/buttons
            .simultaneousGesture(dragGesture)
            .contextMenu { menu }
            .padding(Self.margin) // transparent margin inside the window for shadow room
    }

    /// Move the whole window to follow the cursor, using absolute screen mouse
    /// position so there's no drift and no AppKit edge magnetism. Buttons still
    /// get their taps (this only kicks in past a small movement threshold).
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                let anchor = dragAnchor ?? (mouse, model.currentWindowOrigin?() ?? .zero)
                if dragAnchor == nil { dragAnchor = anchor }
                model.onMoveWindowTo?(CGPoint(
                    x: anchor.origin.x + (mouse.x - anchor.mouse.x),
                    y: anchor.origin.y + (mouse.y - anchor.mouse.y)
                ))
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private var content: some View {
        HStack(spacing: 9) {
            artworkView
            ZStack(alignment: .leading) {
                titleBlock
                    .opacity(hovering ? 0 : 1)
                controlsBlock
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Resting: title + artist

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.track?.name ?? "")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(model.track?.artist ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Hover: large controls (take over the whole text area)

    private var controlsBlock: some View {
        HStack(spacing: 6) {
            ctlButton("backward.fill", size: 14) { model.previous() }
            ctlButton(model.isPlaying ? "pause.fill" : "play.fill", size: 18) { model.playPause() }
            ctlButton("forward.fill", size: 14) { model.next() }
            Spacer(minLength: 4)
            Text(remainingText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.trailing, 2)
        }
    }

    private func ctlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.primary.opacity(0.95))
                .frame(width: 36, height: 34) // generous hit box
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private struct PressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.85 : 1)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let img = model.artwork {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.primary.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        .id(model.track?.id)
        .animation(.easeInOut(duration: 0.35), value: model.track?.id)
        .help("Drag to move • right-click for options")
    }

    // MARK: - Time remaining

    private var remainingText: String {
        guard let d = model.track?.duration, d > 0 else { return "" }
        return "-" + Self.format(max(0, d - model.position))
    }

    private static func format(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Context menu

    @ViewBuilder private var menu: some View {
        Button(model.track?.source == .spotify ? "Open Spotify" : "Open Music") {
            model.openSourceApp()
        }
        Divider()
        Button("Set Default Position") { model.onSetDefault?() }
        Button("Reset to Default Position") { model.onResetPosition?() }
        Button((model.launchAtLogin ? "✓ " : "") + "Start at Login") {
            model.toggleLaunchAtLogin()
        }
        Divider()
        Button("Quit Ledge") { NSApp.terminate(nil) }
    }
}

/// Liquid Glass on macOS 26 (same material family as the dock), frosted fallback earlier.
private struct GlassBackground: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                )
        }
    }
}
