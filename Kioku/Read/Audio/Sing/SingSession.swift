import AVFoundation
import Combine
import Foundation
import LyricAlignment

// Sing mode's live loop: while the song plays, every half second it takes the last 4 s of
// microphone audio, runs the short-window phoneme model over it, and stitches the run's
// well-placed middle into a timeline of the session's own mic time (SingEmissionTimeline).
// Words are graded strictly in lyric order from a cursor, with no song clock: the next few
// words' sounds are placed in order across the audio sung since the last heard word, a word
// turns green once it is found there, and a word is only marked missed after the words past
// it were heard. Verdicts are keyed by the word's UTF-16 start in the note, so the lyrics card
// can colour them. In Line mode it loops the current line, clearing that line's verdicts on
// every pass. In Guided mode (SingSession+Guided) it plays one line at a time and grades the
// singer repeating it.
@MainActor
final class SingSession: ObservableObject {
    @Published private(set) var isActive = false
    @Published var verdicts: [Int: Bool] = [:]
    // What the model heard between the previous heard word and this one, in kana, keyed like `verdicts`.
    @Published var heard: [Int: String] = [:]
    // The most recently graded word, so the lyrics card can show the heard line it belongs to.
    @Published var lastGradedID: Int?
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
    // Guided mode's step within the current line, and that line's cue; nil outside Guided.
    @Published var guidedPhase: SingGuidedPhase?
    @Published var guidedCueIndex: Int?
    // Guided: the current line's words still being listened for this turn, by note location.
    var guidedPending: Set<Int> = []
    // Guided: the words this turn walks through in line order, how many of them have been heard
    // in order so far, and the turn time the last of those ended at, where the next one's search
    // starts (nil until the first is heard).
    var guidedTurnWords: [SingWordTarget] = []
    var guidedTurnHeardCount = 0
    var guidedTurnAnchorSec: Double?
    // Guided: cue index → the words Sing listens for in that line, in line order.
    var guidedLineTargets: [Int: [SingWordTarget]] = [:]
    // Guided: host time the singer's turn opened (the zero of the turn's timeline), and whether
    // the line's playback has been seen running, so its stop marks the end of the line.
    var guidedTurnStartHost: Double = 0
    var guidedSawPlayback = false
    // Guided: what the model heard over the current turn so far, in kana.
    @Published var guidedHeard = ""

    private static let tickSec = 0.5

    // Shared with SingSession+Guided, which runs its own turns on the same mic, model and timeline.
    let mic = SingMicCapture()
    var model: SingPhonemeModel?
    var targets: [SingWordTarget] = []
    private var loop: Task<Void, Never>?
    var isScoring = false
    let timeline = SingEmissionTimeline()
    // Bumped on every jump, so a model run that started before it can't stitch old audio in.
    var generation = 0
    // In-order grading over `timeline`, built per start (SingInOrderGrader), and the host time the
    // session began, the zero of the timeline.
    private var grader: SingInOrderGrader?
    private var sessionStartHost: Double = 0
#if DEBUG
    // Debug builds record the session for scripts/sing-replay (SingSessionDump).
    private var dump: SingSessionDump?
#endif
    private var lastSongSec: Double?
    private var loopCueIndex: Int?
    weak var controller: AudioPlaybackController?
    var cues: [SubtitleCue] = []

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
        guided: Bool = false,
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
        sessionStartHost = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        grader = SingInOrderGrader(targets: targets, passFraction: strictness.passFraction, timeline: timeline)
#if DEBUG
        dump = SingSessionDump(targets: targets, passFraction: strictness.passFraction, classes: SingPhonemeModel.classes, noteText: noteText)
#endif
        placeCursor(atSongSec: Double(controller.currentTimeMs) / 1000)
        loopCueIndex = controller.activeCueIndex
        isActive = true
        if guided {
            // Guided pauses the song while the singer repeats each line, so the speaker never
            // leaks into the mic and no headphones advice is needed.
            scope = .guided
            prepareGuided(noteText: noteText, highlightRanges: highlightRanges)
        } else {
            if scope == .guided { scope = .song }
            isShowingHeadphonesNotice = true
        }
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
#if DEBUG
        dump?.finish(verdicts: verdicts)
        dump = nil
#endif
        mic.stop()
        controller?.isSingRecording = false
        isActive = false
        statusMessage = nil
        isShowingHeadphonesNotice = false
        restoreAudioSource = nil
        guidedPhase = nil
        guidedCueIndex = nil
        guidedPending = []
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

    // Puts the grader's cursor on the first word starting at or after `songSec` (a start, or a seek:
    // the only places the song clock is read) and clears the verdicts from there on, so a repeated
    // or re-entered stretch is graded afresh.
    private func placeCursor(atSongSec songSec: Double) {
        guard let grader else { return }
        for id in grader.seek(toSongSec: songSec) {
            verdicts[id] = nil
            heard[id] = nil
        }
        if let last = lastGradedID, verdicts[last] == nil { lastGradedID = nil }
#if DEBUG
        dump?.addSeek(songSec: songSec)
#endif
    }

    // One pass of the loop: follow seeks, loop the line in Line mode, and grade the words the
    // newest audio has reached.
    private func tick() {
        if guidedPhase != nil { guidedTick(); return }
        guard let controller, let model else { return }
        mic.setAccepting(controller.isPlaying)
        guard controller.isPlaying else { return }

        let songNow = controller.audibleSeconds()
        // A jump (seek, or the line loop) invalidates the buffered audio; grading resumes at the
        // words after the new position.
        if let last = lastSongSec, songNow < last - 0.3 || songNow > last + 2.0 {
            mic.ring.reset()
            generation += 1
            placeCursor(atSongSec: songNow)
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

        guard isScoring == false, let grader, grader.isFinished == false else { return }
        let snapshot = mic.ring.snapshot(count: SingPhonemeModel.windowSamples)
        guard snapshot.samples.count > SingAudioRing.sampleRate, snapshot.newestHostSec > 0 else { return }
        let newest = snapshot.newestHostSec - sessionStartHost
        let windowStart = newest - SingPhonemeModel.windowSec
        let audioStart = newest - Double(snapshot.samples.count) / Double(SingAudioRing.sampleRate)
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
#if DEBUG
            self.dump?.addRun(logProbs: run.values, frames: run.frames, frameSec: run.frameSec, windowStartSec: windowStart,
                              windowSec: SingPhonemeModel.windowSec, audioStartSec: audioStart)
#endif
            self.apply(grader.grade())
        }
    }

    // Shows the grader's verdicts: heard words green, skipped ones red, the heard text kept for the summary.
    private func apply(_ results: [SingVerdict]) {
        for result in results {
            verdicts[result.id] = result.isHeard
            heard[result.id] = result.heard
            lastGradedID = result.id
            AppLog.debug(.audioPlayback, "[Sing] word@\(result.id) \(result.isHeard ? "heard" : "missed") score \(String(format: "%.2f", result.score)) 「\(result.heard)」")
        }
    }
}
