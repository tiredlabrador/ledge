import AppKit
import SwiftUI

/// The player pill. At rest: artwork + title + artist, roomy and centred.
/// On hover: large playback controls take over the whole text area.
/// View-local state. Kept in an ObservableObject rather than `@State`, because
/// on the macOS 27 SDK `@State` is a macro whose plugin ships only with full
/// Xcode — the Command Line Tools we build with can't compile it.
final class WidgetUIState: ObservableObject {
    @Published var hovering = false
    var dragAnchor: (mouse: CGPoint, origin: CGPoint)?
}

struct WidgetView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: WidgetUIState

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
                withAnimation(.smooth(duration: 0.2)) { ui.hovering = h }
                model.hovering = h
            }
            // A hidden or ghosted window stops getting mouse events, so the
            // hover-exit never arrives — reset it ourselves.
            .onChange(of: model.visible) { _, v in if !v { clearHover() } }
            .onChange(of: model.seeThrough) { _, on in if on { clearHover() } }
            .contentShape(Rectangle()) // whole pill is grabbable, not just the art/buttons
            .simultaneousGesture(dragGesture)
            .contextMenu { menu }
            .padding(Self.margin) // transparent margin inside the window for shadow room
    }

    private func clearHover() {
        ui.hovering = false
        model.hovering = false
    }

    /// Move the whole window to follow the cursor, using absolute screen mouse
    /// position so there's no drift and no AppKit edge magnetism. Buttons still
    /// get their taps (this only kicks in past a small movement threshold).
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                let anchor = ui.dragAnchor ?? (mouse, model.currentWindowOrigin?() ?? .zero)
                if ui.dragAnchor == nil { ui.dragAnchor = anchor }
                model.onMoveWindowTo?(CGPoint(
                    x: anchor.origin.x + (mouse.x - anchor.mouse.x),
                    y: anchor.origin.y + (mouse.y - anchor.mouse.y)
                ))
            }
            .onEnded { _ in ui.dragAnchor = nil }
    }

    private var content: some View {
        HStack(spacing: 9) {
            artworkView
            ZStack(alignment: .leading) {
                titleBlock
                    .opacity(ui.hovering ? 0 : 1)
                controlsBlock
                    .opacity(ui.hovering ? 1 : 0)
                    .allowsHitTesting(ui.hovering)
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
            if model.showHideButton {
                Button { model.snooze(PlayerModel.quickHideSeconds) } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Hide for a few seconds")
            }
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
        Button("Copy Song Info") { model.copyTrackInfo() }
            .disabled(model.track == nil)
        Divider()
        Menu("Hide") {
            ForEach(PlayerModel.snoozeOptions, id: \.label) { opt in
                Button("For " + opt.label) { model.snooze(opt.seconds) }
            }
            Divider()
            Button((model.showHideButton ? "\u{2713} " : "") + "Show Hide Button") {
                model.toggleHideButton()
            }
            Button((model.seeThroughEnabled ? "\u{2713} " : "") + "Tap \u{2325} Option to See Through") {
                model.toggleSeeThrough()
            }
        }
        Divider()
        Menu("Position") {
            Button("Set Default Position") { model.onSetDefault?() }
            Button("Reset to Default Position") { model.onResetPosition?() }
        }
        Menu("Auto-Hide After") {
            ForEach(PlayerModel.hideDelayOptions, id: \.label) { opt in
                Button((model.hideDelay == opt.seconds ? "\u{2713} " : "") + opt.label) {
                    model.setHideDelay(opt.seconds)
                }
            }
        }
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
