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

    /// Menu actions: save the current spot as this screen's default, and jump back to it.
    var onSetDefault: (() -> Void)?
    var onResetPosition: (() -> Void)?

    /// Window-drag plumbing, set by the app: read and set the panel's origin so
    /// the view can move the window itself (no AppKit edge magnetism).
    var currentWindowOrigin: (() -> CGPoint)?
    var onMoveWindowTo: ((CGPoint) -> Void)?

    /// Set by the view; visibility logic keeps the widget up while hovered.
    var hovering = false { didSet { onUpdate?() } }

    var onUpdate: (() -> Void)?

    private var lastPlaying = Date.distantPast
    // One queue per source: if scripting one app hangs (Spotify's consent
    // handshake can), the other source keeps updating.
    private let musicQueue = DispatchQueue(label: "ledge.music", qos: .userInitiated)
    private let spotifyQueue = DispatchQueue(label: "ledge.spotify", qos: .userInitiated)
    private var musicBusy = false
    private var spotifyBusy = false
    private var latestMusic = Raw()
    private var latestSpotify = Raw()
    // Artwork fetches run here so they don't wait behind the 1s status polls.
    private let artworkQueue = DispatchQueue(label: "ledge.artwork", qos: .userInitiated)
    private var timer: Timer?
    private var artworkCache: [String: NSImage] = [:]

    private static let musicBundleID = "com.apple.Music"
    private static let spotifyBundleID = "com.spotify.client"

    /// How long the widget lingers after playback stops. `.infinity` = stay put.
    static let hideDelayOptions: [(label: String, seconds: TimeInterval)] = [
        ("10 seconds", 10),
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("Never hide", .infinity)
    ]

    @Published private(set) var hideDelay: TimeInterval =
        (UserDefaults.standard.object(forKey: "LedgeHideDelay") as? Double) ?? 120

    func setHideDelay(_ seconds: TimeInterval) {
        hideDelay = seconds
        UserDefaults.standard.set(seconds, forKey: "LedgeHideDelay")
        onUpdate?()
    }

    /// Temporary manual hide ("get out of the way for a bit"). Always timed, so
    /// the widget can never be hidden with no way to bring it back.
    static let snoozeOptions: [(label: String, seconds: TimeInterval)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("5 minutes", 300)
    ]

    private var hiddenUntil: Date?

    /// How long the hover "hide" button tucks the widget away.
    static let quickHideSeconds: TimeInterval = 5

    /// Set by the app: is the cursor over where the widget sits (even while hidden)?
    var isMouseOverWidget: (() -> Bool)?

    func snooze(_ seconds: TimeInterval) {
        hiddenUntil = Date().addingTimeInterval(seconds)
        hovering = false // drop hover so it actually disappears under the cursor
        onUpdate?()
    }

    // Getting-out-of-the-way options, both on by default.
    @Published private(set) var showHideButton: Bool =
        (UserDefaults.standard.object(forKey: "LedgeHideButton") as? Bool) ?? true
    @Published private(set) var seeThroughEnabled: Bool =
        (UserDefaults.standard.object(forKey: "LedgeSeeThrough") as? Bool) ?? true
    /// Set by the app while the widget is ghosted by the Option key.
    @Published var seeThrough = false

    func toggleHideButton() {
        showHideButton.toggle()
        UserDefaults.standard.set(showHideButton, forKey: "LedgeHideButton")
    }

    func toggleSeeThrough() {
        seeThroughEnabled.toggle()
        UserDefaults.standard.set(seeThroughEnabled, forKey: "LedgeSeeThrough")
        onUpdate?()
    }

    var shouldShow: Bool {
        guard track != nil, sourceRunning else { return false }
        if let until = hiddenUntil {
            // Don't pop back while the cursor is still where the widget sits —
            // it would land on top of whatever you're clicking.
            if Date() < until || (isMouseOverWidget?() ?? false) { return false }
            hiddenUntil = nil
        }
        return isPlaying || hovering || Date().timeIntervalSince(lastPlaying) < hideDelay
    }

    // MARK: - Lifecycle

    /// Sources macOS has told us we may not automate (user declined). We stop
    /// hammering these but retry occasionally in case they change their mind.
    private var denied: [String: Date] = [:]
    private var activatedForPrompt = false

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
        // Treat a terminating app as gone, so we never script it back to life.
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    func poll() {
        pollSource(Self.musicBundleID, script: Self.musicStatusScript,
                   queue: musicQueue, busy: \.musicBusy, latest: \.latestMusic)
        pollSource(Self.spotifyBundleID, script: Self.spotifyStatusScript,
                   queue: spotifyQueue, busy: \.spotifyBusy, latest: \.latestSpotify)
        apply(music: latestMusic, spotify: latestSpotify)
    }

    private func pollSource(_ bundleID: String,
                            script: String,
                            queue: DispatchQueue,
                            busy: ReferenceWritableKeyPath<PlayerModel, Bool>,
                            latest: ReferenceWritableKeyPath<PlayerModel, Raw>) {
        guard isRunning(bundleID) else { self[keyPath: latest] = Raw(); return }
        if let since = denied[bundleID], Date().timeIntervalSince(since) < 60 { return }
        guard !self[keyPath: busy] else { return } // a previous call is still out
        self[keyPath: busy] = true
        queue.async { [weak self] in
            guard let self else { return }
            let r = self.query(script, bundleID: bundleID)
            DispatchQueue.main.async {
                self[keyPath: busy] = false
                self[keyPath: latest] = r
            }
        }
    }

    private func query(_ source: String, bundleID: String) -> Raw {
        // Re-check on the scripting thread, immediately before executing: sending
        // an Apple Event to a quit app relaunches it, so bail if it's gone now.
        guard isRunning(bundleID) else { return Raw() }
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source),
              let out = script.executeAndReturnError(&err).stringValue else {
            if let err {
                let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                NSLog("Ledge query error for %@: %d", bundleID, code)
                switch code {
                case -1743: // user declined automation for this app
                    DispatchQueue.main.async { self.denied[bundleID] = Date() }
                case -1744: // needs consent — the dialog only renders for a
                            // foreground app, so activate once and let the next
                            // poll's Apple Event raise the prompt.
                    DispatchQueue.main.async {
                        guard !self.activatedForPrompt else { return }
                        self.activatedForPrompt = true
                        NSApp.activate(ignoringOtherApps: true)
                    }
                default: break
                }
            }
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
        position = raw.pos
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
            artworkQueue.async { [weak self] in
                guard let self, self.isRunning(Self.musicBundleID) else { return }
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

    private func run(cmd: String) {
        guard let src = track?.source else { return }
        let app = src == .music ? "Music" : "Spotify"
        let bundleID = src == .music ? Self.musicBundleID : Self.spotifyBundleID
        let script = "tell application \"\(app)\" to \(cmd)"
        let q = src == .music ? musicQueue : spotifyQueue
        q.async { [weak self] in
            guard let self, self.isRunning(bundleID) else { return }
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.poll() }
    }

    // MARK: - Misc

    /// Copy "Title Artist" for the current track to the clipboard.
    func copyTrackInfo() {
        guard let t = track else { return }
        let text = t.artist.isEmpty ? t.name : "\(t.name) \(t.artist)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

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
