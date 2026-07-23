import AppKit
import Combine
import ServiceManagement

/// Polls Music.app and Spotify for now-playing state and exposes playback controls.
final class PlayerModel: ObservableObject {

    enum Source { case music, spotify }

    struct Track: Equatable {
        var name: String
        var artist: String
        var id: String
        var duration: Double
        var source: Source
    }

    @Published var track: Track?
    @Published var artwork: NSImage?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var visible = false
    @Published var sourceRunning = false

    /// Whether to tuck the widget against the dock's left edge (needs Accessibility).
    /// Off = bottom-left corner, no extra permission.
    @Published var snapToDock: Bool = (UserDefaults.standard.object(forKey: "LedgeSnapToDock") as? Bool) ?? false

    func setSnap(_ on: Bool) {
        snapToDock = on
        UserDefaults.standard.set(on, forKey: "LedgeSnapToDock")
        onUpdate?()
    }

    /// Set by the view; visibility logic keeps the widget up while hovered.
    var hovering = false { didSet { onUpdate?() } }
    /// While true, polls don't overwrite `position` (user is dragging the bar).
    var scrubbing = false

    var onUpdate: (() -> Void)?

    private var lastPlaying = Date.distantPast
    private let queue = DispatchQueue(label: "ledge.scripting", qos: .userInitiated)
    private var timer: Timer?
    private var artworkCache: [String: NSImage] = [:]

    private static let musicBundleID = "com.apple.Music"
    private static let spotifyBundleID = "com.spotify.client"
    private static let hideDelay: TimeInterval = 120

    var shouldShow: Bool {
        guard track != nil, sourceRunning else { return false }
        return isPlaying || hovering || Date().timeIntervalSince(lastPlaying) < Self.hideDelay
    }

    // MARK: - Lifecycle

    /// Which sources we've confirmed automation consent for. Scripting an app
    /// without consent hangs inside AESendMessage with no visible prompt, so we
    /// explicitly request consent first and only script once granted.
    private var authorized: Set<String> = []
    private var requesting: Set<String> = []

    /// Ask TCC for automation consent (shows the system prompt if needed).
    private func requestConsent(_ bundleID: String) {
        guard !authorized.contains(bundleID), !requesting.contains(bundleID) else { return }
        requesting.insert(bundleID)
        // Blocks while the dialog is up, so keep it off the main thread —
        // one dedicated thread per request, never the scripting queue.
        Thread.detachNewThread { [weak self] in
            var addr = AEAddressDesc()
            let created = bundleID.utf8CString.withUnsafeBufferPointer { buf in
                AECreateDesc(typeApplicationBundleID, buf.baseAddress, buf.count - 1, &addr)
            }
            guard created == noErr else { return }
            let status = AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, true)
            AEDisposeDesc(&addr)
            NSLog("Ledge consent for %@: %d", bundleID, status)
            DispatchQueue.main.async {
                self?.requesting.remove(bundleID)
                if status == noErr { self?.authorized.insert(bundleID); self?.poll() }
            }
        }
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.2

        // Both players broadcast state changes; react instantly instead of waiting for the next poll.
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.Music.playerInfo",
                     "com.apple.iTunes.playerInfo",
                     "com.spotify.client.PlaybackStateChanged"] {
            dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                self?.poll()
            }
        }
    }

    // MARK: - Polling

    private struct Raw {
        var state = "notrunning"
        var pos = 0.0
        var dur = 0.0
        var name = ""
        var artist = ""
        var id = ""
        var artURL: String?
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func poll() {
        if isRunning(Self.musicBundleID) { requestConsent(Self.musicBundleID) }
        if isRunning(Self.spotifyBundleID) { requestConsent(Self.spotifyBundleID) }
        // Only script sources we hold consent for — anything else hangs the queue.
        let queryMusic = authorized.contains(Self.musicBundleID) && isRunning(Self.musicBundleID)
        let querySpotify = authorized.contains(Self.spotifyBundleID) && isRunning(Self.spotifyBundleID)
        guard queryMusic || querySpotify else {
            if track != nil { apply(music: Raw(), spotify: Raw()) }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let m = queryMusic ? self.query(Self.musicStatusScript) : Raw()
            let s = querySpotify ? self.query(Self.spotifyStatusScript) : Raw()
            DispatchQueue.main.async { self.apply(music: m, spotify: s) }
        }
    }

    private func query(_ source: String) -> Raw {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let out = script.executeAndReturnError(&err).stringValue else {
            if let err { NSLog("Ledge query error: %@", err) }
            return Raw()
        }
        let parts = out.components(separatedBy: "|~|")
        guard parts.count >= 6 else { return Raw(state: parts.first ?? "stopped") }
        var r = Raw()
        r.state = parts[0]
        r.pos = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
        r.dur = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        r.name = parts[3]
        r.artist = parts[4]
        r.id = parts[5]
        if parts.count >= 7 { r.artURL = parts[6] }
        return r
    }

    private func apply(music m: Raw, spotify s: Raw) {
        // Whichever app is actually playing wins; otherwise stick with the current source.
        let chosen: (Raw, Source)?
        if m.state == "playing" { chosen = (m, .music) }
        else if s.state == "playing" { chosen = (s, .spotify) }
        else if track?.source == .spotify, !s.id.isEmpty { chosen = (s, .spotify) }
        else if !m.id.isEmpty { chosen = (m, .music) }
        else if !s.id.isEmpty { chosen = (s, .spotify) }
        else { chosen = nil }

        guard let (raw, src) = chosen else {
            track = nil
            artwork = nil
            isPlaying = false
            sourceRunning = false
            onUpdate?()
            return
        }

        sourceRunning = true
        let newTrack = Track(name: raw.name, artist: raw.artist, id: raw.id, duration: raw.dur, source: src)
        let changed = newTrack.id != track?.id || newTrack.source != track?.source
        track = newTrack
        isPlaying = raw.state == "playing"
        if isPlaying { lastPlaying = Date() }
        if !scrubbing { position = raw.pos }
        if changed {
            artwork = artworkCache[newTrack.id]
            fetchArtwork(for: newTrack, urlString: raw.artURL)
        }
        onUpdate?()
    }

    // MARK: - Artwork

    private func fetchArtwork(for t: Track, urlString: String?) {
        if let cached = artworkCache[t.id] {
            artwork = cached
            return
        }
        switch t.source {
        case .spotify:
            guard let url = urlString.flatMap(URL.init(string:)) else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                DispatchQueue.main.async { self?.store(img, for: t) }
            }.resume()
        case .music:
            queue.async { [weak self] in
                guard let self else { return }
                var err: NSDictionary?
                let src = "tell application \"Music\" to get raw data of artwork 1 of current track"
                let desc = NSAppleScript(source: src)?.executeAndReturnError(&err)
                guard let d = desc?.data, !d.isEmpty, let img = NSImage(data: d) else { return }
                DispatchQueue.main.async { self.store(img, for: t) }
            }
        }
    }

    private func store(_ img: NSImage, for t: Track) {
        if artworkCache.count > 30 { artworkCache.removeAll() }
        artworkCache[t.id] = img
        if track?.id == t.id { artwork = img }
    }

    // MARK: - Controls

    func playPause() {
        isPlaying.toggle() // optimistic, corrected by next poll
        if isPlaying { lastPlaying = Date() }
        run(cmd: "playpause")
    }

    func next() { run(cmd: "next track") }

    func previous() {
        // Music's `back track` restarts the song first, then goes back — the native feel.
        run(cmd: track?.source == .music ? "back track" : "previous track")
    }

    func seek(to seconds: Double) {
        position = seconds
        run(cmd: "set player position to \(Int(seconds))")
    }

    private func run(cmd: String) {
        guard let src = track?.source else { return }
        let app = src == .music ? "Music" : "Spotify"
        let script = "tell application \"\(app)\" to \(cmd)"
        queue.async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.poll() }
    }

    // MARK: - Misc

    func openSourceApp() {
        let bid = track?.source == .spotify ? Self.spotifyBundleID : Self.musicBundleID
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLaunchAtLogin() {
        if launchAtLogin {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        objectWillChange.send()
    }

    // MARK: - Scripts

    private static let musicStatusScript = """
    tell application "Music"
        set theState to (player state as string)
        if theState is "playing" or theState is "paused" then
            try
                set t to current track
                return theState & "|~|" & (player position as string) & "|~|" & (duration of t as string) & "|~|" & (name of t) & "|~|" & (artist of t) & "|~|" & (persistent ID of t)
            on error
                return theState
            end try
        end if
        return theState
    end tell
    """

    private static let spotifyStatusScript = """
    tell application "Spotify"
        set theState to (player state as string)
        if theState is "playing" or theState is "paused" then
            try
                set t to current track
                return theState & "|~|" & (player position as string) & "|~|" & (((duration of t) / 1000) as string) & "|~|" & (name of t) & "|~|" & (artist of t) & "|~|" & (id of t) & "|~|" & (artwork url of t)
            on error
                return theState
            end try
        end if
        return theState
    end tell
    """
}
