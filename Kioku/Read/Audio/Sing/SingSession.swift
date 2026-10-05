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
    // The note text the current verdicts were graded against; they're shown only while the note
    // still reads the same (verdicts are keyed by UTF-16 offsets into it).
    @Published private(set) var resultsNoteText: String?
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
            let modelURL = try await SingPhonemeModelStore.ensureModel(onStage: { stage in
                Task { @MainActor [weak self] in self?.statusMessage = stage }
            })
            let loaded = try await Task.detached(priority: .userInitiated) { try SingPhonemeModel(url: modelURL) }.value
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
            statusMessage = error.localizedDescription
            return
        }
        AppLog.info(.audioPlayback, "[Sing] listening for \(targets.count) words")
        verdicts = [:]
        resultsNoteText = noteText
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

    // Stops listening and hands the audio session back to plain playback. Verdicts stay, so the
    // lyrics keep their colours and the summary can list them, until the next start clears them.
    func stop() {
        loop?.cancel(); loop = nil
        mic.stop()
        controller?.isSingRecording = false
        isActive = false
        statusMessage = nil
        isShowingHeadphonesNotice = false
        restoreAudioSource = nil
    }

    // Drops the last session's verdicts, returning the lyrics to their normal colours.
    func clearResults() {
        verdicts = [:]
        resultsNoteText = nil
    }

    // True when there are verdicts graded against exactly this note text.
    func hasResults(for noteText: String) -> Bool {
        verdicts.isEmpty == false && resultsNoteText == noteText
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
        // Due once the word (plus its tail slack and some right context) has been heard and its
        // start is inside the buffered audio; lead slack that falls before the buffer is clipped,
        // so a long held word still gets graded instead of waiting for a moment it fits whole.
        let due = targets.filter { t in
            verdicts[t.id] == nil
                && t.startSec >= audioStart + 0.05
                && t.endSec + t.tailSlackSec <= newestSong - Self.rightContextSec
        }
        guard due.isEmpty == false else { return }

        isScoring = true
        let samples = snapshot.samples
        Task { [weak self] in
            let graded = await Task.detached(priority: .userInitiated) { () -> [(Int, Double)] in
                do {
                    let lp = try model.logProbs(window: samples)
                    let audioFirstFrame = max(0, Int(ceil((audioStart - windowStart) / lp.frameSec)))
                    return due.map { t in
                        let first = max(audioFirstFrame, Int(((t.startSec - t.leadSlackSec) - windowStart) / lp.frameSec))
                        let last = min(lp.frames - 1, Int(((t.endSec + t.tailSlackSec) - windowStart) / lp.frameSec))
                        let result = SingPhonemeScorer.scoreDetails(tokens: t.tokens, logProbs: lp.values, classes: SingPhonemeModel.classes,
                                                                    firstFrame: first, lastFrame: last)
                        Self.logDiagnostics(target: t, score: result.score, placements: result.placements, samples: samples,
                                            windowStart: windowStart, frameSec: lp.frameSec, firstFrame: first, lastFrame: last)
                        return (t.id, result.score)
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
            }
        }
    }

    // One log line per graded word, for tuning and for chasing false misses: the word's expected
    // window, where each expected sound was found (seconds from the word's aligned start) and how
    // sure the model was, and how loud the mic was over the window.
    nonisolated private static func logDiagnostics(
        target t: SingWordTarget, score: Double, placements: [(frame: Int, probability: Float)],
        samples: [Float], windowStart: Double, frameSec: Double, firstFrame: Int, lastFrame: Int
    ) {
        let padded = SingPhonemeModel.windowSamples - samples.count
        let perFrame = Double(SingPhonemeModel.windowSamples) * frameSec / SingPhonemeModel.windowSec
        let lo = max(0, Int(Double(firstFrame) * perFrame) - padded), hi = min(samples.count, Int(Double(lastFrame + 1) * perFrame) - padded)
        var sum: Float = 0
        if hi > lo { for i in lo..<hi { sum += samples[i] * samples[i] } }
        let rmsDb = hi > lo ? 10 * log10(max(1e-10, sum / Float(hi - lo))) : -100
        let found = zip(t.tokens, placements).map { token, placement in
            let offset = windowStart + Double(placement.frame) * frameSec - t.startSec
            return "\(SingPhonemeScorer.label(token))\(String(format: "%+.2f", offset)):\(String(format: "%.2f", placement.probability))"
        }.joined(separator: " ")
        let from = windowStart + Double(firstFrame) * frameSec - t.startSec
        let to = windowStart + Double(lastFrame) * frameSec - t.startSec
        AppLog.debug(.audioPlayback, "[Sing] word@\(t.id) score \(String(format: "%.2f", score)) at \(String(format: "%.2f", t.startSec))s window \(String(format: "%+.2f", from))…\(String(format: "%+.2f", to)) rms \(String(format: "%.0f", rmsDb))dB [\(found)]")
    }
}
