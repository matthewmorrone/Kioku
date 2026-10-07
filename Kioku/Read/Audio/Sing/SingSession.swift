import AVFoundation
import Combine
import Foundation
import LyricAlignment

// Sing mode's live loop: while the song plays, every half second it takes the last 4 s of
// microphone audio, runs the short-window phoneme model over it, stitches the run's well-placed
// middle into a song-time timeline (SingEmissionTimeline), and grades each lyric word whose time
// window the timeline now fully covers. Verdicts are
// keyed by the word's UTF-16 start in the note, so the lyrics card can colour them. In Line
// mode it loops the current line, clearing that line's verdicts on every pass.
@MainActor
final class SingSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var verdicts: [Int: Bool] = [:]
    // What the model heard in each graded word's own time slot, in kana, keyed like `verdicts`.
    @Published private(set) var heard: [Int: String] = [:]
    // The most recently graded word, so the lyrics card can show the heard line it belongs to.
    @Published private(set) var lastGradedID: Int?
    @Published private(set) var statusMessage: String?
    @Published var scope: SingScope = .song
    // Note locations of the words this session listens for, so the lyrics can hide them.
    @Published private(set) var targetIDs: Set<Int> = []
    // How strictly this session grades, and when it started, for the history record.
    private(set) var strictness: SingStrictness = .normal
    private(set) var startedAt: Date?
    // True for the first few seconds of a session, while the lyrics bar shows the headphones advice.
    @Published private(set) var isShowingHeadphonesNotice = false
    // The note text the current verdicts were graded against; they're shown only while the note
    // still reads the same (verdicts are keyed by UTF-16 offsets into it).
    @Published private(set) var resultsNoteText: String?
    // The source that was playing before Sing switched to the instrumental; put back on stop.
    var restoreAudioSource: LyricsAudioSource?

    private static let tickSec = 0.5

    private let mic = SingMicCapture()
    private var model: SingPhonemeModel?
    private var targets: [SingWordTarget] = []
    private var loop: Task<Void, Never>?
    private var isScoring = false
    private let timeline = SingEmissionTimeline()
    // Bumped on every jump, so a model run that started before it can't stitch old audio in.
    private var generation = 0
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
        furigana: [Int: String],
        furiganaLengths: [Int: Int],
        strictness: SingStrictness,
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
                                        segmentRanges: segmentRanges, furigana: furigana,
                                        furiganaLengths: furiganaLengths, romanize: romanize)
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
        heard = [:]
        lastGradedID = nil
        timeline.reset()
        generation += 1
        targetIDs = Set(targets.map(\.id))
        self.strictness = strictness
        startedAt = Date()
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
        heard = [:]
        lastGradedID = nil
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
            timeline.reset()
            generation += 1
            verdicts = verdicts.filter { id, _ in targets.first { $0.id == id }.map { $0.startSec < songNow - 0.3 } ?? false }
            heard = heard.filter { id, _ in verdicts[id] != nil }
            if let last = lastGradedID, verdicts[last] == nil { lastGradedID = nil }
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
        let samples = snapshot.samples
        let runGeneration = generation

        isScoring = true
        Task { [weak self] in
            let run = await Task.detached(priority: .userInitiated) { () -> (values: [Float], frames: Int, frameSec: Double)? in
                do {
                    return try model.logProbs(window: samples)
                } catch {
                    AppLog.error(.audioPlayback, "[Sing] model run failed: \(error.localizedDescription)")
                    return nil
                }
            }.value
            guard let self else { return }
            self.isScoring = false
            guard self.isActive, let run, runGeneration == self.generation else { return }
            self.timeline.merge(logProbs: run.values, frames: run.frames, frameSec: run.frameSec, classes: SingPhonemeModel.classes,
                                windowStartSec: windowStart, windowSec: SingPhonemeModel.windowSec, audioStartSec: audioStart)
            self.gradeDueWords(samples: samples, audioStartSec: audioStart)
        }
    }

    // Grades every word whose window (lead slack, word, tail slack) the timeline now covers and
    // whose start it reaches; lead slack from before the timeline's first frame is clipped.
    private func gradeDueWords(samples: [Float], audioStartSec: Double) {
        guard let earliest = timeline.earliestSec else { return }
        let due = targets.filter { t in
            verdicts[t.id] == nil && t.startSec >= earliest && t.endSec + t.tailSlackSec <= timeline.coveredUntilSec
        }
        for t in due {
            guard let window = timeline.slice(fromSec: t.startSec - t.leadSlackSec, toSec: t.endSec + t.tailSlackSec) else { continue }
            let result = SingPhonemeScorer.scoreDetails(tokens: t.tokens, logProbs: window.values, classes: SingPhonemeModel.classes,
                                                        firstFrame: 0, lastFrame: window.frames - 1)
            // The heard line uses the word's own slot, without slack, so it doesn't pick up its neighbours.
            let heard = timeline.slice(fromSec: t.startSec, toSec: t.endSec).map {
                SingHeardDecoder.kana(logProbs: $0.values, classes: SingPhonemeModel.classes, firstFrame: 0, lastFrame: $0.frames - 1)
            } ?? ""
            Self.logDiagnostics(target: t, score: result.score, heard: heard, placements: result.placements,
                                windowStartSec: window.startSec, windowFrames: window.frames, frameSec: timeline.frameSec,
                                samples: samples, audioStartSec: audioStartSec)
            verdicts[t.id] = result.score >= strictness.passFraction
            self.heard[t.id] = heard
            lastGradedID = t.id
        }
    }

    // One log line per graded word, for tuning and for chasing false misses: the word's expected
    // window, where each expected sound was found (seconds from the word's aligned start) and how
    // sure the model was, and how loud the mic was over the window.
    private static func logDiagnostics(
        target t: SingWordTarget, score: Double, heard: String, placements: [(frame: Int, probability: Float)],
        windowStartSec: Double, windowFrames: Int, frameSec: Double, samples: [Float], audioStartSec: Double
    ) {
        let windowEndSec = windowStartSec + Double(windowFrames - 1) * frameSec
        // Loudness over the part of the window still in the newest mic snapshot.
        let rate = Double(SingAudioRing.sampleRate)
        let lo = max(0, Int((windowStartSec - audioStartSec) * rate)), hi = min(samples.count, Int((windowEndSec - audioStartSec) * rate))
        var sum: Float = 0
        if hi > lo { for i in lo..<hi { sum += samples[i] * samples[i] } }
        let rmsDb = hi > lo ? 10 * log10(max(1e-10, sum / Float(hi - lo))) : -100
        let found = zip(t.tokens, placements).map { token, placement in
            let offset = windowStartSec + Double(placement.frame) * frameSec - t.startSec
            return "\(SingPhonemeScorer.label(token))\(String(format: "%+.2f", offset)):\(String(format: "%.2f", placement.probability))"
        }.joined(separator: " ")
        let from = windowStartSec - t.startSec, to = windowEndSec - t.startSec
        AppLog.debug(.audioPlayback, "[Sing] word@\(t.id) score \(String(format: "%.2f", score)) at \(String(format: "%.2f", t.startSec))s window \(String(format: "%+.2f", from))…\(String(format: "%+.2f", to)) rms \(String(format: "%.0f", rmsDb))dB heard「\(heard)」 [\(found)]")
    }
}
