import AVFoundation
import Combine
import Foundation
import LyricAlignment

// Sing mode's live loop: while the song plays, every half second it takes the last 4 s of
// microphone audio, runs the short-window phoneme model over it, and grades each lyric word
// whose time window has fully passed (with a little audio after it for context). Verdicts are
// keyed by the word's UTF-16 start in the note, so the lyrics card can colour them. In Line
// mode it loops the current line, clearing that line's verdicts on every pass.
@MainActor
final class SingSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var verdicts: [Int: Bool] = [:]
    @Published private(set) var statusMessage: String?
    @Published var scope: SingScope = .song
    // True for the first few seconds of a session, while the lyrics bar shows the headphones advice.
    @Published private(set) var isShowingHeadphonesNotice = false
    // The source that was playing before Sing switched to the instrumental; put back on stop.
    var restoreAudioSource: LyricsAudioSource?

    private static let tickSec = 0.5
    // Frames in the last stretch of a window lack right-hand context; never grade from them.
    private static let rightContextSec = 0.4

    private let mic = SingMicCapture()
    private var model: SingPhonemeModel?
    private var targets: [SingWordTarget] = []
    private var loop: Task<Void, Never>?
    private var isScoring = false
    private var lastSongSec: Double?
    private var loopCueIndex: Int?
    private weak var controller: AudioPlaybackController?
    private var cues: [SubtitleCue] = []

    // Starts listening: mic permission, the play-and-record session, model load and word plan.
    // Leaves `statusMessage` set (and stays off) when any of them fails.
    func start(
        controller: AudioPlaybackController,
        cues: [SubtitleCue],
        noteText: String,
        highlightRanges: [NSRange?],
        segmentRanges: [NSRange],
        romanize: @escaping @Sendable (String) -> [RomanizedSpan]
    ) async {
        guard isActive == false else { return }
        statusMessage = "Starting…"
        guard await AVAudioApplication.requestRecordPermission() else {
            statusMessage = "Microphone access is off. Turn it on in Settings › Kioku."
            return
        }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { try SingPhonemeModel() }.value
            let planned = await Task.detached(priority: .userInitiated) {
                SingWordPlanner.targets(cues: cues, noteText: noteText, highlightRanges: highlightRanges,
                                        segmentRanges: segmentRanges, romanize: romanize)
            }.value
            model = loaded
            targets = planned
            self.cues = cues
            self.controller = controller
            controller.isSingRecording = true
            try mic.start()
        } catch {
            AppLog.error(.audioPlayback, "[Sing] start failed: \(error.localizedDescription)")
            controller.isSingRecording = false
            statusMessage = model == nil ? "Sing model not installed (HubertPhonemeSing.mlmodelc)." : error.localizedDescription
            return
        }
        AppLog.info(.audioPlayback, "[Sing] listening for \(targets.count) words")
        verdicts = [:]
        statusMessage = nil
        lastSongSec = nil
        loopCueIndex = controller.activeCueIndex
        isActive = true
        isShowingHeadphonesNotice = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.isShowingHeadphonesNotice = false
        }
        loop = Task { [weak self] in
            while Task.isCancelled == false {
                self?.tick()
                try? await Task.sleep(for: .seconds(Self.tickSec))
            }
        }
    }

    // Stops listening and hands the audio session back to plain playback.
    func stop() {
        loop?.cancel(); loop = nil
        mic.stop()
        controller?.isSingRecording = false
        isActive = false
        verdicts = [:]
        statusMessage = nil
        isShowingHeadphonesNotice = false
        restoreAudioSource = nil
    }

    // One pass of the loop: follow pauses and seeks, loop the line in Line mode, and grade
    // whatever words the newest audio now covers.
    private func tick() {
        guard let controller, let model else { return }
        mic.setAccepting(controller.isPlaying)
        guard controller.isPlaying else { lastSongSec = nil; return }

        let songNow = controller.audibleSeconds()
        let hostNow = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        // A jump (seek, or the line loop) invalidates the buffered audio and re-opens the words ahead.
        if let last = lastSongSec, songNow < last - 0.3 || songNow > last + 2.0 {
            mic.ring.reset()
            verdicts = verdicts.filter { id, _ in targets.first { $0.id == id }.map { $0.startSec < songNow - 0.3 } ?? false }
            if scope == .line, let loopCue = loopCueIndex, loopCue < cues.count,
               songNow * 1000 < Double(cues[loopCue].startMs) - 500 || songNow * 1000 > Double(cues[loopCue].endMs) + 1500 {
                loopCueIndex = controller.activeCueIndex
            }
        }
        lastSongSec = songNow
        if scope == .line, let loopCue = loopCueIndex ?? controller.activeCueIndex, loopCue < cues.count {
            loopCueIndex = loopCue
            if songNow * 1000 >= Double(cues[loopCue].endMs) + 800 {
                controller.seek(toMs: cues[loopCue].startMs)
                return
            }
        } else if scope == .song {
            loopCueIndex = nil
        }

        guard isScoring == false else { return }
        let snapshot = mic.ring.snapshot(count: SingPhonemeModel.windowSamples)
        guard snapshot.samples.count > SingAudioRing.sampleRate, snapshot.newestHostSec > 0 else { return }
        let newestSong = songNow - (hostNow - snapshot.newestHostSec)
        let windowStart = newestSong - SingPhonemeModel.windowSec
        let audioStart = newestSong - Double(snapshot.samples.count) / Double(SingAudioRing.sampleRate)
        let due = targets.filter { t in
            verdicts[t.id] == nil
                && t.startSec - SingPhonemeScorer.leadSlackSec >= audioStart
                && t.endSec + SingPhonemeScorer.tailSlackSec <= newestSong - Self.rightContextSec
        }
        guard due.isEmpty == false else { return }

        isScoring = true
        let samples = snapshot.samples
        Task { [weak self] in
            let graded = await Task.detached(priority: .userInitiated) { () -> [(Int, Double)] in
                do {
                    let lp = try model.logProbs(window: samples)
                    return due.map { t in
                        let first = Int(((t.startSec - SingPhonemeScorer.leadSlackSec) - windowStart) / lp.frameSec)
                        let last = min(lp.frames - 1, Int(((t.endSec + SingPhonemeScorer.tailSlackSec) - windowStart) / lp.frameSec))
                        return (t.id, SingPhonemeScorer.score(tokens: t.tokens, logProbs: lp.values, classes: SingPhonemeModel.classes,
                                                              firstFrame: max(0, first), lastFrame: last))
                    }
                } catch {
                    AppLog.error(.audioPlayback, "[Sing] model run failed: \(error.localizedDescription)")
                    return []
                }
            }.value
            guard let self else { return }
            self.isScoring = false
            guard self.isActive else { return }
            for (id, score) in graded {
                self.verdicts[id] = score >= SingPhonemeScorer.passFraction
                AppLog.debug(.audioPlayback, "[Sing] word@\(id) score \(String(format: "%.2f", score))")
            }
        }
    }
}
