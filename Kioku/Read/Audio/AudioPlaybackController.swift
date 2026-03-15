import AVFoundation
import Foundation

// Controls MP3/audio playback and publishes the current subtitle cue index so ReadView can
// drive real-time text highlighting without any UI logic inside this class.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTimeMs: Int = 0
    @Published var duration: TimeInterval = 0
    // Index into the cues array for the currently active subtitle; nil when between cues or stopped.
    @Published var activeCueIndex: Int? = nil

    private var player: AVAudioPlayer?
    private var cues: [SubtitleCue] = []
    private var timer: Timer?

    // Loads audio from a URL and stores the cue list for highlight resolution.
    // Throws if AVAudioPlayer cannot open the file.
    func load(audioURL: URL, cues: [SubtitleCue]) throws {
        stop()
        let newPlayer = try AVAudioPlayer(contentsOf: audioURL)
        newPlayer.prepareToPlay()
        player = newPlayer
        self.cues = cues
        duration = newPlayer.duration
        currentTimeMs = 0
        activeCueIndex = nil
    }

    // Unloads audio and resets all state when switching away from a note with audio.
    func unload() {
        stop()
        player = nil
        cues = []
        duration = 0
        currentTimeMs = 0
        activeCueIndex = nil
    }

    // Starts playback and begins polling for the current cue.
    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    // Pauses playback and takes one final time snapshot.
    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateCurrentTime()
    }

    // Stops playback and resets position to the start.
    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
        currentTimeMs = 0
        activeCueIndex = nil
    }

    // Seeks to a specific millisecond offset without interrupting the play/pause state.
    func seek(toMs ms: Int) {
        guard let player else { return }
        player.currentTime = TimeInterval(ms) / 1000.0
        updateCurrentTime()
    }

    // Schedules a 50 ms polling timer to keep currentTimeMs and activeCueIndex fresh during playback.
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCurrentTime()
            }
        }
    }

    // Cancels the polling timer when playback is no longer active.
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // Reads the current player position and resolves which cue (if any) is active at that time.
    private func updateCurrentTime() {
        guard let player else { return }
        let ms = Int(player.currentTime * 1000)
        currentTimeMs = ms

        // Stop state is already handled; check if playback has reached the end naturally.
        if player.isPlaying == false && isPlaying {
            isPlaying = false
            stopTimer()
            activeCueIndex = nil
            return
        }

        activeCueIndex = cues.firstIndex { cue in
            ms >= cue.startMs && ms < cue.endMs
        }
    }
}
