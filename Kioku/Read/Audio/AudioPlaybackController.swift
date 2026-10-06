import AVFoundation
import Combine
import Foundation
import MediaPlayer

// Controls MP3/audio playback and publishes the current subtitle cue index so ReadView can drive real-time text highlighting without any UI logic inside this class.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTimeMs: Int = 0
    @Published var duration: TimeInterval = 0
    // Index into the cues array for the currently active subtitle; nil when between cues or stopped.
    @Published var activeCueIndex: Int? = nil
    // Beat grid and loudness curve of the loaded file, for the lyrics view's interlude notes.
    // Nil until the background analysis finishes (or if it fails).
    @Published private(set) var pulseMap: SongPulseMap?
    // Guards against a slow analysis of a previous file landing after a newer load.
    private var pulseAnalysisID = UUID()
    // Latest AVAudioSession output latency, refreshed each timer tick for `audibleSeconds()`.
    private var outputLatencySec: TimeInterval = 0
    // Fired when AVAudioPlayer stops on its own having reached the end of the file — distinct
    // from an explicit `pause()`/`stop()` call (including `playRange`'s scheduled auto-pause at
    // a line's end, which always calls `pause()` before the player would reach true EOF). Used
    // by SongStepperView to know when a full listen-along track — not just one line's clip —
    // has finished, for the "continue to the next note" setting.
    var onDidFinishPlayingNaturally: (() -> Void)? = nil
    // Fired when a `playRange` call reaches its `endMs` and auto-pauses (not on an explicit
    // pause or seek). Lets the breakdown chain its intro into the first line.
    var onDidFinishRange: (() -> Void)? = nil

    private var player: AVAudioPlayer?
    var cues: [SubtitleCue] = []
    private var timer: Timer?
    // When set, the timer tick pauses playback once `currentTimeMs` reaches this value.
    // Used by `playRange(startMs:endMs:)` as a *backstop* — the primary stop signal is the
    // `stopWorkItem` dispatched at the precise end time below. The timer-based check exists
    // for the case where the work item is somehow dropped (it's a belt-and-braces guard).
    // Cleared by any explicit seek/stop so it never leaks into subsequent unrelated playback.
    private var stopAtMs: Int? = nil
    // Scheduled main-queue work item that pauses playback at the upper bound of an
    // active `playRange(startMs:endMs:)` call. Unlike the polling timer, an
    // `asyncAfter`-scheduled block fires regardless of run-loop mode — so a scroll
    // gesture (which puts the run loop in `.tracking` and suspends default-mode timers)
    // cannot delay the auto-pause. Cancelled and re-created by each `playRange` call;
    // cancelled by any explicit seek/stop so it never lingers into unrelated playback.
    private var stopWorkItem: DispatchWorkItem? = nil
    // Logged once per playback start so the karaoke debug log shows the I/O latency we
    // subtracted from AVAudioPlayer.currentTime. Reset to false on pause/stop so the
    // next play() re-reads it (route may have changed mid-pause, e.g., AirPods reconnect).
    private var didLogOutputLatency = false
    // Title shown on the lock screen / Control Center Now Playing card. Set by `load()`;
    // `nil` leaves the previous track's title in place, which never happens in practice since
    // `load()` is always called with one before playback can start.
    private var nowPlayingTitle: String?
    // Furigana runs per cue (index-aligned with `cues`) for the lyrics Live Activity, supplied by
    // the Read screen's LyricsActivityRubyFeeder since the furigana tables live with the note.
    // Empty or mismatched → the activity falls back to the cue's plain text.
    var cueRubyRuns: [[LyricsActivityRubyRun]] = [] {
        didSet { syncLyricsActivity() }
    }
    private let lyricsActivity = LyricsLiveActivityController()

    override init() {
        super.init()
        configureAudioSession()
        configureRemoteCommandCenter()
        NotificationCenter.default.addObserver(self, selector: #selector(otherPlayerStarted(_:)), name: ExclusivePlayback.didStart, object: nil)
    }

    // Pauses when another of the app's players starts (ExclusivePlayback): one sound at a time.
    @objc private func otherPlayerStarted(_ notification: Notification) {
        guard notification.object as AnyObject? !== self, isPlaying else { return }
        pause()
    }

    // Wires the lock-screen / Control Center transport buttons to this controller. Registered
    // once for the controller's lifetime — MPRemoteCommandCenter is a process-wide singleton,
    // but only the app's single ReadView-owned controller instance ever plays audio, so there's
    // no competing claimant to hand commands off to.
    private func configureRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.isPlaying ? self.pause() : self.play()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, self.player != nil,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(toMs: Int(event.positionTime * 1000))
            return .success
        }
    }

    // Publishes the current track/position to the system Now Playing card (lock screen,
    // Control Center, connected CarPlay/AirPlay endpoints). Only `elapsedPlaybackTime` and
    // `rate` need refreshing on every seek/play/pause — the system interpolates the displayed
    // elapsed time between updates from those two values, so this doesn't need to run on the
    // 50ms polling timer.
    private func updateNowPlayingInfo() {
        syncLyricsActivity()
        guard let player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        // With a lyric to show, the line takes the title slot (the most prominent text on every
        // Now Playing surface) and the note title drops to the artist slot. Without one, the
        // artist slot is cleared so a previous line's layout doesn't linger.
        if let lyric = nowPlayingLyricLine() {
            info[MPMediaItemPropertyTitle] = lyric
            info[MPMediaItemPropertyArtist] = nowPlayingTitle ?? "Kioku"
        } else {
            info[MPMediaItemPropertyTitle] = nowPlayingTitle ?? "Kioku"
            info[MPMediaItemPropertyArtist] = nil
        }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // The lyric line the Now Playing card should show, or nil to show the plain note title.
    // Nil when the setting is off, when nothing is loaded or playing position has no cue, or when
    // the cue is blank. Only the first line of a multi-line cue is used — the card truncates
    // anyway, and the first line is the one being sung.
    private func nowPlayingLyricLine() -> String? {
        guard AudioSettings.lyricsOnNowPlayingEnabled,
              let index = activeCueIndex, index >= 0, index < cues.count else { return nil }
        let firstLine = LyricsActivityRubyBuilder.firstLine(of: cues[index].text)
        return firstLine.isEmpty ? nil : firstLine
    }

    // Pushes the current line and play state to the lyrics Live Activity. Rides along with every
    // Now Playing refresh (play, pause, seek, stop, line change), which are exactly the moments
    // the activity's content can change; the activity controller drops unchanged states.
    private func syncLyricsActivity() {
        lyricsActivity.sync(title: nowPlayingTitle, state: lyricsActivityState())
    }

    // The Live Activity's content for the active cue, or nil when nothing is loaded or no cue is
    // active (which ends the activity). The next line skips blank cues so the preview isn't empty.
    private func lyricsActivityState() -> LyricsActivityState? {
        guard player != nil, let index = activeCueIndex, index >= 0, index < cues.count else { return nil }
        // Runs built for a different cue list (the feeder hasn't caught up with a new note yet)
        // are ignored rather than risk pairing a line with another line's furigana.
        let runs = cueRubyRuns.count == cues.count ? cueRubyRuns[index] : []
        let line = runs.isEmpty
            ? LyricsActivityRubyBuilder.plainRuns(LyricsActivityRubyBuilder.firstLine(of: cues[index].text))
            : runs
        let nextLine = cues[(index + 1)...]
            .lazy
            .map { LyricsActivityRubyBuilder.firstLine(of: $0.text) }
            .first { $0.isEmpty == false }
        return LyricsActivityState(line: line, nextLine: nextLine, isPlaying: isPlaying)
    }

    // Picks the session category based on the user's Background Audio setting.
    // .playback ignores the ringer/silent switch and keeps playing in the background (the
    // UIBackgroundModes "audio" entitlement is set in Info.plist); .ambient does neither.
    // Mode must match the category: .spokenAudio is only valid with .playback, so the
    // .ambient branch uses .default. Called fresh on each play() so toggling the setting
    // takes effect without an app restart.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // setCategory can fail transiently when iOS is mid-route-switch (call interruption,
        // AirPods reconnect). Log instead of swallowing so "playback started but no sound"
        // bug reports have something to point at.
        do {
            if AudioSettings.backgroundPlaybackEnabled {
                try session.setCategory(.playback, mode: .spokenAudio)
            } else {
                try session.setCategory(.ambient, mode: .default)
            }
        } catch {
            AppLog.error(.audioPlayback, "[AudioPlaybackController] setCategory failed: \(error.localizedDescription)")
        }
    }

    // Loads audio from a URL and stores the cue list for highlight resolution. `title` names
    // the track on the lock screen / Control Center Now Playing card.
    // Throws if AVAudioPlayer cannot open the file.
    func load(audioURL: URL, cues: [SubtitleCue], title: String? = nil) throws {
        stop()
        // The activity's title is fixed at creation, so a new track gets a fresh activity on
        // its first play rather than an update.
        lyricsActivity.end()
        let newPlayer = try AVAudioPlayer(contentsOf: audioURL)
        newPlayer.prepareToPlay()
        player = newPlayer
        self.cues = cues
        analyzePulse(of: audioURL)
        nowPlayingTitle = title
        duration = AudioFileDuration.seconds(of: audioURL) ?? newPlayer.duration
        currentTimeMs = 0
        syncTimeAndCue()
        updateNowPlayingInfo()
    }

    // Swaps the underlying audio file (original mix ↔ isolated vocal stem) WITHOUT changing cues
    // or yanking the playhead: captures the current position + play state, opens the new file,
    // seeks to the same time, and resumes if we were playing. The stem and the mix are the same
    // length, so the position maps 1:1. Throws if the new file can't open (caller keeps the old
    // source). No-op-safe: if no player is loaded yet it behaves like `load` with empty cues kept.
    func switchSource(to audioURL: URL) throws {
        let wasPlaying = isPlaying
        let positionSec = player?.currentTime ?? 0
        let keptCues = cues
        let newPlayer = try AVAudioPlayer(contentsOf: audioURL)
        newPlayer.prepareToPlay()
        player?.pause()
        stopTimer()
        player = newPlayer
        cues = keptCues
        duration = AudioFileDuration.seconds(of: audioURL) ?? newPlayer.duration
        newPlayer.currentTime = min(max(0, positionSec), max(0, duration - 0.05))
        if wasPlaying {
            configureAudioSession()
            try? AVAudioSession.sharedInstance().setActive(true)
            newPlayer.play()
            isPlaying = true
            startTimer()
        } else {
            isPlaying = false
        }
        syncTimeAndCue()
        updateNowPlayingInfo()
    }

    // Replaces the cue list in place without disturbing the loaded player or the current
    // playback position. Used by in-place lyric editing where calling `load()` would be too
    // heavy — `load()` stops playback and seeks to 0, which would yank the user out of the
    // line they're correcting after every nudge. Re-resolves the active cue immediately so
    // the karaoke highlight tracks the edited boundaries on the very next frame.
    func updateCues(_ cues: [SubtitleCue]) {
        self.cues = cues
        syncTimeAndCue()
    }

    // Unloads audio and resets all state when switching away from a note with audio.
    func unload() {
        stop()
        player = nil
        cues = []
        pulseMap = nil
        pulseAnalysisID = UUID()
        duration = 0
        currentTimeMs = 0
        activeCueIndex = nil
        nowPlayingTitle = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            AppLog.error(.audioPlayback, "[AudioPlaybackController] setActive(false) failed: \(error.localizedDescription)")
        }
        updateNowPlayingInfo()
    }

    // Starts or resumes playback. Begins polling for the current cue.
    // Starts from position 0 if not already mid-song (currentTimeMs == 0), otherwise resumes.
    func play() {
        guard let player else {
            KaraokeDebugLog.log("controller.play: NO player loaded — early exit")
            return
        }
        configureAudioSession()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AppLog.error(.audioPlayback, "[AudioPlaybackController] play setActive(true) failed: \(error.localizedDescription)")
        }
        ExclusivePlayback.claim(self)
        player.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
        KaraokeDebugLog.log("controller.play: started cuesCount=\(cues.count)")
    }

    // Starts playback from the beginning regardless of current position.
    func playFromStart() {
        guard let player else { return }
        configureAudioSession()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            AppLog.error(.audioPlayback, "[AudioPlaybackController] playFromStart setActive(true) failed: \(error.localizedDescription)")
        }
        ExclusivePlayback.claim(self)
        player.currentTime = 0
        currentTimeMs = 0
        player.play()
        isPlaying = true
        startTimer()
        syncTimeAndCue()
        updateNowPlayingInfo()
    }

    // Pauses playback and takes one final time snapshot.
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        cancelStopWorkItem()
        didLogOutputLatency = false
        syncTimeAndCue()
        updateNowPlayingInfo()
    }

    // Stops playback and resets position to the start.
    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
        cancelStopWorkItem()
        currentTimeMs = 0
        activeCueIndex = nil
        stopAtMs = nil
        didLogOutputLatency = false
        updateNowPlayingInfo()
    }

    // Plays a contiguous millisecond range, automatically pausing at `endMs`. Used by the
    // breakdown stepper's "play this line" affordance — the SRT cue for a line gives the
    // start/end ms and we want exactly that span to play, not a full-song scrub from the
    // line's start.
    //
    // Order matters: seek first (which clears any prior `stopAtMs` and pending stop-work),
    // then install the new bound, schedule the precise auto-pause work item, then start
    // playback. AVFoundation doesn't have a native "play until X" primitive — the scheduled
    // `DispatchWorkItem` is what reliably stops at `endMs` regardless of whether the
    // polling timer is currently being suppressed by run-loop tracking mode.
    func playRange(startMs: Int, endMs: Int) {
        guard player != nil else { return }
        let clampedEnd = max(startMs + 1, endMs)
        seek(toMs: startMs)
        stopAtMs = clampedEnd
        scheduleStopWorkItem(durationMs: clampedEnd - startMs)
        play()
    }

    // Schedules the auto-pause for a `playRange` call. Cancels any previously-scheduled
    // item so a rapid succession of line-play taps doesn't queue up multiple pauses. The
    // block re-checks `stopWorkItem === self.stopWorkItem` semantics implicitly by being
    // cancelled-and-replaced — once `cancel()` is called on the old item, its captured
    // closure won't run even if it was already dispatched.
    private func scheduleStopWorkItem(durationMs: Int) {
        stopWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // The body runs on the main queue (we dispatched it there), but the work-item
            // closure itself isn't `@MainActor`-isolated by Swift concurrency's rules — so
            // we hop onto a MainActor task for the actual state mutation, matching the
            // pattern already used for `startTimer`'s tick callback.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stopAtMs = nil
                self.stopWorkItem = nil
                self.pause()
                self.onDidFinishRange?()
            }
        }
        stopWorkItem = item
        let delay = DispatchTimeInterval.milliseconds(max(0, durationMs))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // Tears down any pending `playRange` auto-pause. Called from seek/pause/stop/unload so
    // the work item never fires after the user has redirected playback.
    private func cancelStopWorkItem() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
    }

    // Pauses playback and seeks back to the beginning. Called when the lyrics view is dismissed.
    func resetToStart() {
        player?.pause()
        player?.currentTime = 0
        isPlaying = false
        stopTimer()
        currentTimeMs = 0
        syncTimeAndCue()
        updateNowPlayingInfo()
    }

    // Seeks to a specific millisecond offset without interrupting the play/pause state.
    // Resumes playback after seeking if we were playing, since AVAudioPlayer can
    // momentarily stop during currentTime assignment. Any pending `stopAtMs` watchdog is
    // cleared — the user moved the cursor, so a previously-armed line-range stop no longer
    // matches what they're listening to.
    func seek(toMs ms: Int) {
        guard let player else { return }
        let wasPlaying = player.isPlaying
        player.currentTime = TimeInterval(ms) / 1000.0
        stopAtMs = nil
        cancelStopWorkItem()
        if wasPlaying && player.isPlaying == false {
            player.play()
        }
        // Resolve from the EXACT sought time — do NOT apply the output-latency correction here.
        // That correction assumes audio is continuously buffered ahead of the decode position,
        // which isn't true immediately after a seek (most visibly while paused). Subtracting
        // latency from a freshly-sought cue boundary resolves `startMs − latency`, landing back
        // in the previous cue (e.g. the ♪ line above) — that's the drag-to-line "rebound". The
        // timer path keeps applying the correction during continuous playback.
        let target = max(0, ms)
        currentTimeMs = target
        resolveActiveCue(atMs: target)
        updateNowPlayingInfo()
    }

    // Schedules a 50 ms polling timer to keep currentTimeMs and activeCueIndex fresh during playback.
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
    }

    // Cancels the polling timer when playback is no longer active.
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // Timer-driven update that checks for natural end-of-playback and refreshes time/cue.
    private func timerTick() {
        guard let player else { return }

        // Detect natural end-of-playback (player stopped on its own).
        if player.isPlaying == false && isPlaying {
            isPlaying = false
            stopTimer()
            // A playRange ending at the file's end must not also fire its range-end callback.
            cancelStopWorkItem()
            stopAtMs = nil
            activeCueIndex = nil
            onDidFinishPlayingNaturally?()
            return
        }

        syncTimeAndCue()

        // Auto-pause at the line-range upper bound when `playRange` armed one.
        if let stopAt = stopAtMs, currentTimeMs >= stopAt {
            stopAtMs = nil
            pause()
            onDidFinishRange?()
        }
    }

    // Analyzes the file's beats and loudness off the main thread for the interlude notes. The
    // result is dropped if another file was loaded (or this one unloaded) in the meantime.
    private func analyzePulse(of audioURL: URL) {
        pulseMap = nil
        let id = UUID()
        pulseAnalysisID = id
        Task { [weak self] in
            let map = await Task.detached(priority: .utility) {
                SongPulseAnalyzer.analyze(url: audioURL)
            }.value
            guard let self, self.pulseAnalysisID == id else { return }
            self.pulseMap = map
        }
    }

    // What the listener is hearing right now, in seconds — read straight from the player so
    // per-frame animation (the interlude notes) moves smoothly between the 50 ms timer ticks.
    // Same latency correction as `syncTimeAndCue`.
    func audibleSeconds() -> Double {
        guard let player, isPlaying else { return Double(currentTimeMs) / 1000 }
        return max(0, player.currentTime - outputLatencySec)
    }

    // Reads the current player position and resolves which cue is active at that time.
    // Called from both seek and the polling timer — never checks end-of-playback so that
    // seeking during playback cannot accidentally kill the timer.
    //
    // I/O latency correction: AVAudioPlayer.currentTime reports the decode position —
    // the moment a sample is handed to the system mixer. The user hears samples that
    // are already in the output buffer (≈10-50ms wired, ≈100-200ms AirPods/Bluetooth).
    // Without subtracting AVAudioSession.outputLatency, the karaoke band sits on the
    // syllable about to be sung, not the one being heard, perceived as a consistent
    // lead especially on wireless routes. Subtracting once here keeps the band aligned
    // with the audible audio across all consumers (cue index resolution AND the per-
    // word checkpoint lookup that drives the highlight band) — they all read
    // currentTimeMs, so the correction lives at the single source.
    private func syncTimeAndCue() {
        guard let player else { return }
        outputLatencySec = AVAudioSession.sharedInstance().outputLatency
        if didLogOutputLatency == false {
            didLogOutputLatency = true
            KaraokeDebugLog.log("controller: outputLatency=\(Int(outputLatencySec * 1000))ms (subtracted from player.currentTime for karaoke alignment)")
        }
        let ms = max(0, Int(player.currentTime * 1000 - outputLatencySec * 1000))
        if currentTimeMs != ms {
            currentTimeMs = ms
        }
        resolveActiveCue(atMs: ms)
    }

    // Resolves `activeCueIndex` for a given playback time. Split out of `syncTimeAndCue` so the
    // seek path can resolve from the exact sought time (no latency correction) while the timer
    // path resolves from the latency-corrected time — both share one cue-lookup rule.
    private func resolveActiveCue(atMs ms: Int) {
        let currentCue = cues.firstIndex { ms >= $0.startMs && ms < $0.endMs }
        let nextCue = cues.firstIndex { $0.startMs > ms }
        let previousCue = cues.lastIndex { $0.endMs <= ms }
        let newActiveCueIndex = currentCue ?? nextCue ?? previousCue ?? activeCueIndex
        if activeCueIndex != newActiveCueIndex {
            KaraokeDebugLog.log("controller.cue: \(activeCueIndex.map(String.init) ?? "nil") → \(newActiveCueIndex.map(String.init) ?? "nil") at t=\(ms)ms (cues.count=\(cues.count))")
            activeCueIndex = newActiveCueIndex
            // Line changed: push it to the Now Playing card. Cheap (one dictionary write) and
            // only runs on cue transitions, not every timer tick.
            updateNowPlayingInfo()
        }
    }
}
