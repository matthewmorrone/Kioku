import AVFoundation
import Combine
import Foundation

// Controls MP3/audio playback and publishes the current subtitle cue index so ReadView can drive real-time text highlighting without any UI logic inside this class.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTimeMs: Int = 0
    @Published var duration: TimeInterval = 0
    // Index into the cues array for the currently active subtitle; nil when between cues or stopped.
    @Published var activeCueIndex: Int? = nil
    // Smoothed audio level in [0, 1], driven by AVAudioPlayer's average-power meter. Updated on
    // every timer tick while playing. Consumers (e.g., the lyrics ♪ pulse) treat this as a coarse
    // rhythm signal — louder samples pulse bigger. Set to 0 when paused/stopped so visuals can
    // react to the playback state without an additional gate.
    @Published var audioLevel: Double = 0

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

    override init() {
        super.init()
        configureAudioSession()
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
            print("[AudioPlaybackController] setCategory failed: \(error.localizedDescription)")
        }
    }

    // Loads audio from a URL and stores the cue list for highlight resolution.
    // Throws if AVAudioPlayer cannot open the file.
    func load(audioURL: URL, cues: [SubtitleCue]) throws {
        stop()
        let newPlayer = try AVAudioPlayer(contentsOf: audioURL)
        newPlayer.isMeteringEnabled = true
        newPlayer.prepareToPlay()
        player = newPlayer
        self.cues = cues
        duration = newPlayer.duration
        currentTimeMs = 0
        syncTimeAndCue()
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
        newPlayer.isMeteringEnabled = true
        newPlayer.prepareToPlay()
        player?.pause()
        stopTimer()
        player = newPlayer
        cues = keptCues
        duration = newPlayer.duration
        newPlayer.currentTime = min(max(0, positionSec), max(0, newPlayer.duration - 0.05))
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
        duration = 0
        currentTimeMs = 0
        activeCueIndex = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[AudioPlaybackController] setActive(false) failed: \(error.localizedDescription)")
        }
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
            print("[AudioPlaybackController] play setActive(true) failed: \(error.localizedDescription)")
        }
        player.play()
        isPlaying = true
        startTimer()
        KaraokeDebugLog.log("controller.play: started cuesCount=\(cues.count)")
    }

    // Starts playback from the beginning regardless of current position.
    func playFromStart() {
        guard let player else { return }
        configureAudioSession()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioPlaybackController] playFromStart setActive(true) failed: \(error.localizedDescription)")
        }
        player.currentTime = 0
        currentTimeMs = 0
        player.play()
        isPlaying = true
        startTimer()
        syncTimeAndCue()
    }

    // Pauses playback and takes one final time snapshot.
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        cancelStopWorkItem()
        audioLevel = 0
        didLogOutputLatency = false
        syncTimeAndCue()
    }

    // Stops playback and resets position to the start.
    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
        cancelStopWorkItem()
        currentTimeMs = 0
        activeCueIndex = nil
        audioLevel = 0
        stopAtMs = nil
        didLogOutputLatency = false
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
            activeCueIndex = nil
            audioLevel = 0
            return
        }

        syncTimeAndCue()
        updateAudioLevel(player)

        // Auto-pause at the line-range upper bound when `playRange` armed one.
        if let stopAt = stopAtMs, currentTimeMs >= stopAt {
            stopAtMs = nil
            pause()
        }
    }

    // Reads AVAudioPlayer's per-channel average-power meter, averages stereo channels into a
    // single value, normalizes the -160…0 dB range into [0, 1], and exponentially smooths so
    // the published `audioLevel` doesn't strobe on every 50ms tick. The smoothing time
    // constant is tuned to feel beat-like without being twitchy — visible peaks on kick drums
    // and snare hits, no jitter on sustained vowels.
    private func updateAudioLevel(_ player: AVAudioPlayer) {
        player.updateMeters()
        let channelCount = max(1, player.numberOfChannels)
        var sumDb: Float = 0
        for ch in 0..<channelCount {
            sumDb += player.averagePower(forChannel: ch)
        }
        let avgDb = sumDb / Float(channelCount)
        // -50 dB → ~silence, 0 dB → peak. Clamp and normalize.
        let normalized = max(0.0, min(1.0, Double((avgDb + 50) / 50)))
        // Exponential smoothing — 0.35 of new sample, 0.65 retained.
        audioLevel = audioLevel * 0.65 + normalized * 0.35
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
        let outputLatencySec = AVAudioSession.sharedInstance().outputLatency
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
        }
    }
}
