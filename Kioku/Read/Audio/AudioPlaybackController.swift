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
        if AudioSettings.backgroundPlaybackEnabled {
            try? session.setCategory(.playback, mode: .spokenAudio)
        } else {
            try? session.setCategory(.ambient, mode: .default)
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

    // Unloads audio and resets all state when switching away from a note with audio.
    func unload() {
        stop()
        player = nil
        cues = []
        duration = 0
        currentTimeMs = 0
        activeCueIndex = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Starts or resumes playback. Begins polling for the current cue.
    // Starts from position 0 if not already mid-song (currentTimeMs == 0), otherwise resumes.
    func play() {
        guard let player else {
            KaraokeDebugLog.log("controller.play: NO player loaded — early exit")
            return
        }
        configureAudioSession()
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startTimer()
        KaraokeDebugLog.log("controller.play: started cuesCount=\(cues.count)")
    }

    // Starts playback from the beginning regardless of current position.
    func playFromStart() {
        guard let player else { return }
        configureAudioSession()
        try? AVAudioSession.sharedInstance().setActive(true)
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
        audioLevel = 0
        syncTimeAndCue()
    }

    // Stops playback and resets position to the start.
    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
        currentTimeMs = 0
        activeCueIndex = nil
        audioLevel = 0
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
    // momentarily stop during currentTime assignment.
    func seek(toMs ms: Int) {
        guard let player else { return }
        let wasPlaying = player.isPlaying
        player.currentTime = TimeInterval(ms) / 1000.0
        if wasPlaying && player.isPlaying == false {
            player.play()
        }
        syncTimeAndCue()
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
    private func syncTimeAndCue() {
        guard let player else { return }
        let ms = Int(player.currentTime * 1000)
        if currentTimeMs != ms {
            currentTimeMs = ms
        }

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
