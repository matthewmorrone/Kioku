import AVFoundation
import Combine
import Foundation

// Plays a SongBreakdown's listen-along script live, one step at a time, instead of
// pre-rendering it into a file: each step (a sung clip from the note's own audio, or a
// speech segment) starts only once the previous one has actually finished, and the
// controller always knows — and publishes — exactly which step is in flight. There is no
// second array (cues recorded once at render time, replayed against a segment list rebuilt
// later) that can drift out of sync with what's actually playing; `currentSegment` IS the
// thing being spoken right now.
//
// Runs on-device via AVSpeechSynthesizer's live `speak(_:)`, not the buffer-capture
// `write(_:toBufferCallback:)` API the old file-rendering approach used — which means the
// synthesizer's own `willSpeak(characterRange:)` delegate callback gives real per-word
// timing for the currently-speaking sentence, not an estimate interpolated from a recorded
// clip duration.
//
// Background playback: relies on the app's existing "audio" UIBackgroundModes entitlement
// plus an active `.playback`/`.spokenAudio` AVAudioSession (configured in `beginSession()`),
// exactly like any background-audio app — the OS keeps the process running as long as the
// session stays active and audio keeps being produced, tiny gaps between steps included.
@MainActor
final class SongLiveListenController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    // The segment currently being spoken — or, for a `.clip` step, a synthetic sentence-kind
    // segment carrying the line's text so the Japanese row highlights while the sung clip
    // plays, mirroring what a speech step for that same line would look like.
    @Published private(set) var currentSegment: SongListenSegment?
    // Fractional progress (0...1) through the active `.sentence` segment's spoken text, driven
    // by AVSpeechSynthesizer's live per-character callback. Nil outside a single-run sentence
    // step (a mixed-language sentence splits into multiple runs — rare — skips fine tracking).
    @Published private(set) var sentenceProgress: Double?
    // Set when this device is missing a required voice, or the audio session couldn't be
    // activated. Surfaced by the toolbar's listen button as a retry-able failure state.
    @Published private(set) var lastError: String?

    // Fired when playback reaches the end of the script on its own (not via an explicit
    // pause/stop, and not via a `playLine` bound finishing its one line) — mirrors
    // AudioPlaybackController's identically-named field, used by SongStepperView to advance
    // to the next note when that setting is on.
    var onDidFinishPlayingNaturally: (() -> Void)?

    private var steps: [SongListenStep] = []
    private var sourceAudioURL: URL?
    private var originalByLineIndex: [Int: String] = [:]
    private var currentStepIndex = 0
    // Set by `playLine` so `advance` stops (without firing the natural-finish callback) once
    // it steps past this line's last step, instead of continuing into the next line.
    private var stopAfterLineIndex: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private var clipPlayer: AVAudioPlayer?
    private var scheduledWork: DispatchWorkItem?

    // The same-language runs of the segment currently being synthesized (code-switching
    // within one segment, e.g. an English gist quoting a Japanese word — see
    // SongListenLanguageRuns) and which one is in flight.
    private var pendingRuns: [SongListenSegmentRun] = []
    private var pendingRunIndex = 0
    // Character length of the full spoken text for the active single-run sentence step, so a
    // live `willSpeak` character range can be turned into a 0...1 fraction.
    private var activeSpokenTextLength = 0

    private var japaneseVoice: AVSpeechSynthesisVoice?
    private var englishVoice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // Loads a new script. A no-op when it's the same script and source already loaded, so a
    // SwiftUI body re-evaluation (this is called on every relevant body pass, not cached by
    // the caller) never interrupts playback in progress. Anything actually different stops
    // playback and starts over from the top — same as a regenerated breakdown invalidating
    // the old file-based render.
    //
    // Called eagerly (SongStepperView calls this as soon as the breakdown/clip ranges are
    // ready, not just when the user taps play) so the expensive one-time work below —
    // opening the note's source audio file and resolving TTS voices — happens well before the
    // first tap instead of on its critical path.
    func configure(steps: [SongListenStep], sourceAudioURL: URL?, originalByLineIndex: [Int: String]) {
        guard steps != self.steps || sourceAudioURL != self.sourceAudioURL else { return }
        let sourceChanged = sourceAudioURL != self.sourceAudioURL
        stop()
        self.steps = steps
        self.sourceAudioURL = sourceAudioURL
        self.originalByLineIndex = originalByLineIndex
        if sourceChanged {
            loadClipPlayer()
        }
        if japaneseVoice == nil || englishVoice == nil {
            resolveVoices()
        }
    }

    // Opens the note's source audio file once (off the main thread) and keeps it around for
    // every `.clip` step to seek within — NOT one `AVAudioPlayer` per clip. Re-opening a
    // multi-minute song file on every synced line was the actual cause of a real, repeated
    // "significant delay" between lines (not just once at the start): AVAudioPlayer's
    // synchronous initializer decodes/prepares the whole file, and doing that on the main
    // thread once per line stutters the whole song, not just the first play tap.
    private func loadClipPlayer() {
        clipPlayer = nil
        guard let sourceAudioURL else { return }
        Task.detached(priority: .userInitiated) {
            guard let player = try? AVAudioPlayer(contentsOf: sourceAudioURL) else { return }
            player.prepareToPlay()
            await MainActor.run { [weak self] in
                // Only adopt it if nothing else (a newer configure() call) has since changed
                // which source URL is current.
                guard let self, self.sourceAudioURL == sourceAudioURL else { return }
                self.clipPlayer = player
            }
        }
    }

    // Resolves and caches the Japanese/English TTS voices once, so later calls (beginSession's
    // own fallback included) don't repeat the lookup.
    private func resolveVoices() {
        japaneseVoice = Self.preferredVoice(languageCode: "ja-JP")
        englishVoice = Self.preferredVoice(languageCode: "en-US")
    }

    // Starts or resumes playback of the whole script from `currentStepIndex` — 0 on first
    // play, or wherever a previous pause/line-bound stop left off (re-saying the current
    // step from its start is fine; there is no mid-utterance resume).
    func play() {
        guard steps.isEmpty == false else { return }
        stopAfterLineIndex = nil
        beginSession()
        guard lastError == nil else { return }
        advance(startingAt: currentStepIndex)
    }

    // Plays just one line's steps (its clip, sentence, gist, and words) and stops there. On
    // the line currently parked as `currentSegment` (e.g. paused mid-line), resumes from that
    // step; on any other line, starts from its first step.
    func playLine(_ lineIndex: Int) {
        let start: Int
        if currentSegment?.lineIndex == lineIndex,
           steps.indices.contains(currentStepIndex),
           stepLineIndex(steps[currentStepIndex]) == lineIndex {
            start = currentStepIndex
        } else {
            guard let firstIndex = steps.firstIndex(where: { stepLineIndex($0) == lineIndex }) else { return }
            start = firstIndex
        }
        stopAfterLineIndex = lineIndex
        beginSession()
        guard lastError == nil else { return }
        advance(startingAt: start)
    }

    // Pauses in place: the synthesizer/clip stop immediately, but `currentStepIndex` and
    // `currentSegment` are left exactly where they were so `play()` resumes from this same
    // step rather than the next one.
    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        synthesizer.stopSpeaking(at: .immediate)
        // `.pause()`, not `.stop()` — this player is kept loaded and reused for every clip
        // step (see `loadClipPlayer`), not torn down between lines.
        clipPlayer?.pause()
        cancelScheduledWork()
    }

    // Full stop: rewinds to the top of the script and releases the audio session. Called when
    // the Listen sheet/screen goes away or the breakdown it was narrating is replaced.
    func stop() {
        isPlaying = false
        stopAfterLineIndex = nil
        synthesizer.stopSpeaking(at: .immediate)
        // Paused, not torn down — see `loadClipPlayer`'s header comment. It's only replaced
        // when `configure()` sees a genuinely different source URL.
        clipPlayer?.pause()
        cancelScheduledWork()
        currentSegment = nil
        sentenceProgress = nil
        currentStepIndex = 0
        deactivateSession()
    }

    // MARK: - Stepping

    private func stepLineIndex(_ step: SongListenStep) -> Int {
        switch step {
        case .speech(let segment): return segment.lineIndex
        case .clip(let lineIndex, _, _): return lineIndex
        }
    }

    // Runs the step at `index`, or stops appropriately once there's nothing left to run: the
    // natural end of the whole script when unbounded, or a quiet pause (no callback) once a
    // `playLine` bound's line is behind us.
    private func advance(startingAt index: Int) {
        if let boundLine = stopAfterLineIndex {
            guard index < steps.count, stepLineIndex(steps[index]) == boundLine else {
                pause()
                stopAfterLineIndex = nil
                return
            }
        } else {
            guard index < steps.count else {
                finishNaturally()
                return
            }
        }

        currentStepIndex = index
        isPlaying = true
        switch steps[index] {
        case .speech(let segment):
            currentSegment = segment
            runSpeech(segment)
        case .clip(let lineIndex, let startMs, let endMs):
            currentSegment = SongListenSegment(lineIndex: lineIndex, kind: .sentence, text: originalByLineIndex[lineIndex] ?? "", language: .japanese)
            sentenceProgress = nil
            runClip(startMs: startMs, endMs: endMs)
        }
    }

    // Reached the end of an unbounded (whole-script) playback on its own: resets to the top
    // and notifies the caller, distinct from an explicit pause/stop or a `playLine` bound.
    private func finishNaturally() {
        isPlaying = false
        currentSegment = nil
        sentenceProgress = nil
        currentStepIndex = 0
        deactivateSession()
        onDidFinishPlayingNaturally?()
    }

    // Advances to the next step after the short gap appropriate to what just finished —
    // matching the old file-render's silence durations so the listening experience (pace
    // between a word and its definition vs. between lines) is unchanged.
    private func completeCurrentStep() {
        guard isPlaying else { return }
        let gap = gapSeconds(after: currentSegment?.kind)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying else { return }
            self.advance(startingAt: self.currentStepIndex + 1)
        }
        scheduledWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + gap, execute: item)
    }

    // The silence duration after a finished step, by what kind of segment it was — matches the
    // old file-render's per-kind silences (SongListenAudioSink.writeSilence) so the pacing of
    // the listening experience is unchanged.
    private func gapSeconds(after kind: SongListenSegmentKind?) -> Double {
        switch kind {
        case .sentence, nil: return 0.5
        case .translation: return 0.7
        case .wordSurface: return 0.15
        case .wordDefinition: return 0.45
        case .patternNote: return 0.7
        }
    }

    // Cancels whatever inter-step/inter-run/clip-stop timer is currently pending, if any —
    // called by pause/stop so a stale timer can't fire an advance after playback has stopped.
    private func cancelScheduledWork() {
        scheduledWork?.cancel()
        scheduledWork = nil
    }

    // MARK: - Speech

    private func runSpeech(_ segment: SongListenSegment) {
        let spokenText = segment.spokenText ?? segment.text
        let runs = SongListenLanguageRuns.split(spokenText, defaultLanguage: segment.language)
        pendingRuns = runs
        pendingRunIndex = 0
        activeSpokenTextLength = spokenText.count
        // Only a single-run sentence has one character space to report progress against — a
        // mixed-language sentence (rare) has no single run to map back onto `line.original`'s
        // word ranges, so it stays nil (no per-word highlight) rather than getting stuck at 0%.
        sentenceProgress = (segment.kind == .sentence && runs.count == 1) ? 0 : nil
        speakCurrentRun()
    }

    // Speaks whichever run `pendingRunIndex` currently points at, with the voice matching its
    // language. A no-op once every run in `pendingRuns` has already been spoken.
    private func speakCurrentRun() {
        guard pendingRunIndex < pendingRuns.count else { return }
        let run = pendingRuns[pendingRunIndex]
        let utterance = AVSpeechUtterance(string: run.text)
        utterance.voice = run.language == .japanese ? japaneseVoice : englishVoice
        synthesizer.speak(utterance)
    }

    // A run finished: move to the next run in this segment (a brief inter-voice beat, same as
    // the old sink's writeSilenceBetweenVoices), or complete the whole step once the last run
    // is done.
    private func handleUtteranceFinished() {
        guard isPlaying else { return }
        pendingRunIndex += 1
        if pendingRunIndex < pendingRuns.count {
            let item = DispatchWorkItem { [weak self] in
                self?.speakCurrentRun()
            }
            scheduledWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
            return
        }
        completeCurrentStep()
    }

    // Live per-character progress within the run currently being spoken. Only tracked for a
    // `.sentence` segment that synthesizes as a single run — a mixed-language sentence (rare)
    // has no single character space to map back onto `line.original`'s word ranges, so it
    // skips fine-grained tracking rather than reporting something misleading.
    private func handleWillSpeak(range: NSRange) {
        guard currentSegment?.kind == .sentence, pendingRuns.count == 1, activeSpokenTextLength > 0 else { return }
        let consumed = range.location + range.length
        sentenceProgress = min(1, max(0, Double(consumed) / Double(activeSpokenTextLength)))
    }

    // MARK: - Clips

    // Plays the [startMs, endMs) slice of the note's own audio live, stopping on a timer
    // rather than waiting for natural end-of-file — the source file is the whole song, not
    // just this line. Reuses the one `clipPlayer` `loadClipPlayer` already opened (the common
    // case — by the time any line plays, the background load from `configure()` has long since
    // finished); the synchronous open here is only a rare fallback for a tap that lands before
    // that background load completes.
    private func runClip(startMs: Int, endMs: Int) {
        guard let sourceAudioURL else {
            completeCurrentStep()
            return
        }
        let player: AVAudioPlayer
        if let existing = clipPlayer {
            player = existing
        } else if let loaded = try? AVAudioPlayer(contentsOf: sourceAudioURL) {
            loaded.prepareToPlay()
            clipPlayer = loaded
            player = loaded
        } else {
            completeCurrentStep()
            return
        }
        let clampedEndMs = min(endMs, Int(player.duration * 1000))
        let durationMs = max(0, clampedEndMs - startMs)
        player.currentTime = TimeInterval(startMs) / 1000
        player.play()
        let item = DispatchWorkItem { [weak self] in
            self?.clipPlayer?.pause()
            self?.completeCurrentStep()
        }
        scheduledWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(durationMs) / 1000, execute: item)
    }

    // MARK: - Session + voices

    private func beginSession() {
        lastError = nil
        if japaneseVoice == nil || englishVoice == nil {
            japaneseVoice = Self.preferredVoice(languageCode: "ja-JP")
            englishVoice = Self.preferredVoice(languageCode: "en-US")
        }
        guard japaneseVoice != nil, englishVoice != nil else {
            lastError = "This device doesn't have the Japanese and English voices needed for listen-along audio."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Releases the audio session so other apps can resume audio once this controller is done
    // with it — called on a full stop or the script's natural end, not on a mere pause.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Picks the best-quality installed voice for a language: premium, else enhanced, else
    // whatever `AVSpeechSynthesisVoice(language:)` resolves to. Same preference the old
    // file-rendering service used — premium/enhanced voices sound distinctly more natural for
    // a longer narrated track than the plain system default used elsewhere for a one-word
    // tap-to-hear.
    private static func preferredVoice(languageCode: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        if let best = candidates.max(by: { qualityRank($0.quality) < qualityRank($1.quality) }) {
            return best
        }
        return AVSpeechSynthesisVoice(language: languageCode)
    }

    // Orders voice quality tiers so `preferredVoice`'s `max(by:)` picks premium over enhanced
    // over the plain default.
    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: return 2
        case .enhanced: return 1
        case .default: return 0
        @unknown default: return 0
        }
    }
}

extension SongLiveListenController: AVSpeechSynthesizerDelegate {
    // Hops back onto the main actor to advance the script once an utterance completes.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.handleUtteranceFinished() }
    }

    // Cancellation is always our own doing (pause/stop), which already set `isPlaying` false
    // before calling `stopSpeaking` — `handleUtteranceFinished`'s own guard makes this a no-op,
    // so nothing further is needed here.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    }

    // Hops back onto the main actor to publish live per-character sentence progress.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.handleWillSpeak(range: characterRange) }
    }
}

// What the breakdown toolbar's listen button shows: headphones (tap to play everything in
// sequence), pause while anything is playing, or a warning (missing voices / session
// activation failure) that retries on tap. Own type per the repo's no-nested-types rule.
enum SongListenControlState: Equatable {
    case idle
    case playing
    case failed
}
