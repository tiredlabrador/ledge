import SwiftUI

/// The player pill. At rest: artwork + title + artist, roomy and centred.
/// On hover: large playback controls take over the whole text area, and a
/// scrubbable progress bar fades in along the bottom.
struct WidgetView: View {
    @ObservedObject var model: PlayerModel
    @State private var hovering = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    // Keep in sync with AppDelegate.glassW / glassH / margin.
    static let glassW: CGFloat = 270
    static let glassH: CGFloat = 60
    static let margin: CGFloat = 16

    // Left inset that lines the progress bar up with the text (art + paddings).
    private let textInset: CGFloat = 9 + 46 + 9

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
            .contextMenu { menu }
            .padding(Self.margin) // transparent margin inside the window for shadow room
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
        // Progress bar overlaid on the bottom edge, aligned under the text only,
        // fading in on hover so the resting pill stays clean and uncramped.
        .overlay(alignment: .bottomLeading) {
            progressBar
                .padding(.leading, textInset)
                .padding(.trailing, 10)
                .padding(.bottom, 4)
                .opacity(hovering ? 1 : 0)
                .animation(.smooth(duration: 0.2), value: hovering)
        }
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
        .onTapGesture { model.openSourceApp() }
        .help("Open in \(model.track?.source == .spotify ? "Spotify" : "Music")")
    }

    // MARK: - Progress / scrubbing

    private var displayedPosition: Double { scrubbing ? scrubValue : model.position }

    private var remainingText: String {
        guard let d = model.track?.duration, d > 0 else { return "" }
        return "-" + Self.format(max(0, d - displayedPosition))
    }

    private static func format(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dur = model.track?.duration ?? 0
            let frac = dur > 0 ? min(1, max(0, displayedPosition / dur)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.18))
                Capsule().fill(.primary.opacity(scrubbing ? 1 : 0.85))
                    .frame(width: max(3, w * frac))
            }
            .frame(height: scrubbing ? 5 : 3.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle().inset(by: -9)) // large grab area above/below the line
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard dur > 0 else { return }
                        scrubbing = true
                        model.scrubbing = true
                        scrubValue = min(dur, max(0, Double(v.location.x / w) * dur))
                    }
                    .onEnded { _ in
                        guard dur > 0 else { scrubbing = false; model.scrubbing = false; return }
                        model.seek(to: scrubValue)
                        scrubbing = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { model.scrubbing = false }
                    }
            )
        }
        .frame(height: 12)
    }

    // MARK: - Context menu

    @ViewBuilder private var menu: some View {
        Button(model.track?.source == .spotify ? "Open Spotify" : "Open Music") {
            model.openSourceApp()
        }
        Divider()
        Button((model.snapToDock ? "✓ " : "") + "Snap next to Dock") {
            model.setSnap(!model.snapToDock)
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
