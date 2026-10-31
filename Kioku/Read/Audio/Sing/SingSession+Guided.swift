import AVFoundation
import Foundation
import LyricAlignment

// Guided Sing: one line at a time, the song sings it, then pauses while the singer repeats it.
// The singer's turn has no song clock, so its audio is stitched on a timeline that starts when
// the turn opens, and the line's words are placed in order wherever they were sung
// (SingPhonemeScorer.wordScores). The words are heard in sequence: a word turns green only once
// every word before it in the turn is green and it was sung after them; at the end of the turn
// the rest turn red, and a retry is sung from the first red word on.
extension SingSession {
    // How long a turn listens beyond the line's own length, for a slow start and a slower pace.
    private static let guidedTurnSlackSec = 2.5
    private static let guidedTurnStretch = 1.3
    // Pause before moving on from a line sung all correct, so the green has a moment to show.
    private static let guidedAdvanceDelaySec = 1.2

    // Groups the planned words by line and picks the line to start on: the one playing, else
    // the first sung line. Leaves the session ready in .review until the first line is played.
    func prepareGuided(noteText: String, highlightRanges: [NSRange?]) {
        let noteNS = noteText as NSString
        var byCue: [Int: [SingWordTarget]] = [:]
        for index in cues.indices {
            guard let line = SingWordPlanner.lineRange(ofCueAt: index, cues: cues, noteNS: noteNS, highlightRanges: highlightRanges) else { continue }
            let words = targets.filter { NSLocationInRange($0.id, line) }.sorted { $0.id < $1.id }
            if words.isEmpty == false { byCue[index] = words }
        }
        guidedLineTargets = byCue
        let lines = byCue.keys.sorted()
        let current = controller?.activeCueIndex ?? 0
        guidedCueIndex = lines.first { $0 >= current } ?? lines.first
        guidedPhase = .review
        guidedPending = []
    }

    // Plays the current line from the start, clearing its results, then opens the singer's turn.
    func guidedPlayLine() {
        guard let index = guidedCueIndex else { return }
        let ids = Set((guidedLineTargets[index] ?? []).map(\.id))
        clearVerdicts(for: ids)
        startListening(to: index, then: ids)
    }

    // Plays the current line again, then listens only for the words still missed (the whole line
    // when none were missed).
    func guidedReplay() {
        guard let index = guidedCueIndex else { return }
        let missed = guidedMissed(in: index)
        if missed.isEmpty { guidedPlayLine() } else { startListening(to: index, then: missed) }
    }

    // Opens a turn straight away for the current line's missed words; the green ones stay.
    func guidedRetryMissed() {
        guard let index = guidedCueIndex else { return }
        let missed = guidedMissed(in: index)
        guard missed.isEmpty == false else { return }
        openTurn(for: missed)
    }

    // Moves to the next (or previous) sung line and plays it.
    func guidedStep(by offset: Int) {
        let lines = guidedLineTargets.keys.sorted()
        guard let index = guidedCueIndex, let position = lines.firstIndex(of: index) else { return }
        let next = position + offset
        guard lines.indices.contains(next) else { return }
        guidedCueIndex = lines[next]
        guidedPlayLine()
    }

    // True when there is a sung line before / after the current one.
    var guidedHasPrevious: Bool { guidedLineTargets.keys.contains { $0 < (guidedCueIndex ?? 0) } }
    var guidedHasNext: Bool { guidedLineTargets.keys.contains { $0 > (guidedCueIndex ?? Int.max) } }

    // The current line's words, and how many of them are green, for the guided bar.
    var guidedLineWordCount: Int { guidedCueIndex.flatMap { guidedLineTargets[$0]?.count } ?? 0 }
    var guidedLineHeardCount: Int {
        guard let index = guidedCueIndex else { return 0 }
        return (guidedLineTargets[index] ?? []).filter { verdicts[$0.id] == true }.count
    }

    // Note locations of the line's words graded red.
    func guidedMissed(in index: Int) -> Set<Int> {
        Set((guidedLineTargets[index] ?? []).map(\.id).filter { verdicts[$0] == false })
    }

    // Ends the singer's turn now: words not heard yet are marked missed.
    func guidedFinishTurn() {
        guard guidedPhase == .yourTurn else { return }
        for id in guidedPending { verdicts[id] = false }
        guidedPending = []
        closeTurn()
    }

    // Guided's half-second step: notices the line's playback ending, and during a turn feeds the
    // newest mic audio to the model and grades it, ending the turn on time or once all are heard.
    func guidedTick() {
        guard let controller, let index = guidedCueIndex, index < cues.count else { return }
        switch guidedPhase {
        case .listening:
            if controller.isPlaying {
                guidedSawPlayback = true
            } else if guidedSawPlayback {
                // Parked on the line's start, so the lyrics show the line being repeated.
                controller.seek(toMs: cues[index].startMs)
                openTurn(for: guidedPending)
            }
        case .yourTurn:
            let cue = cues[index]
            let limit = Double(cue.endMs - cue.startMs) / 1000 * Self.guidedTurnStretch + Self.guidedTurnSlackSec
            let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - guidedTurnStartHost
            if elapsed >= limit {
                guidedFinishTurn()
                return
            }
            scoreTurn()
        case .review, nil:
            return
        }
    }

    // Plays cue `index` and, once it stops, opens a turn listening for `ids`.
    private func startListening(to index: Int, then ids: Set<Int>) {
        guard let controller, index < cues.count else { return }
        generation += 1
        mic.setAccepting(false)
        guidedPending = ids
        guidedSawPlayback = false
        guidedPhase = .listening
        controller.playRange(startMs: cues[index].startMs, endMs: cues[index].endMs)
    }

    // Starts listening for `ids` on a fresh timeline whose zero is now. The turn walks the line
    // from the first of `ids` to the last, in order. On a retry that span can hold words already
    // green: they stay green whatever this turn hears, but they still have to be sung in their
    // place, so a missed word after them is only searched for after they are heard again. Green
    // words past the last missed one are left out, so the turn ends once that word is heard.
    private func openTurn(for ids: Set<Int>) {
        controller?.pause()
        guidedHeard = ""
        generation += 1
        timeline.reset()
        mic.setAccepting(true)
        guidedPending = ids
        let line = guidedCueIndex.flatMap { guidedLineTargets[$0] } ?? []
        if let first = line.firstIndex(where: { ids.contains($0.id) }),
           let last = line.lastIndex(where: { ids.contains($0.id) }) {
            guidedTurnWords = Array(line[first...last])
        } else {
            guidedTurnWords = []
        }
        guidedTurnHeardCount = 0
        guidedTurnAnchorSec = nil
        guidedTurnStartHost = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        guidedPhase = .yourTurn
    }

    // Stops listening and shows the line's results; a line sung all correct moves on by itself.
    private func closeTurn() {
        generation += 1
        mic.setAccepting(false)
        guidedPhase = .review
        guard let index = guidedCueIndex, guidedMissed(in: index).isEmpty, guidedHasNext else { return }
        let turnGeneration = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.guidedAdvanceDelaySec))
            guard let self, self.isActive, self.generation == turnGeneration, self.guidedPhase == .review else { return }
            self.guidedStep(by: 1)
        }
    }

    // Runs the model over the newest mic audio, stitches it onto the turn's timeline and walks
    // the turn's words not yet heard, in order, from where the last heard one ended: each word
    // that passes turns green and moves the start of the search past it, and the first word that
    // fails stops the walk, so nothing after it can turn green in this pass. Green is final for
    // the turn; red only comes when the turn ends.
    private func scoreTurn() {
        guard isScoring == false, let model, let index = guidedCueIndex else { return }
        let snapshot = mic.ring.snapshot(count: SingPhonemeModel.windowSamples)
        guard snapshot.samples.count > SingAudioRing.sampleRate, snapshot.newestHostSec > 0 else { return }
        let newest = snapshot.newestHostSec - guidedTurnStartHost
        let windowStart = newest - SingPhonemeModel.windowSec
        let audioStart = newest - Double(snapshot.samples.count) / Double(SingAudioRing.sampleRate)
        let samples = snapshot.samples
        let runGeneration = generation
        guard guidedTurnHeardCount < guidedTurnWords.count else { return }

        isScoring = true
        Task { [weak self] in
            let run = await Task.detached(priority: .userInitiated) { () -> (values: [Float], frames: Int, frameSec: Double)? in
                do {
                    return try model.logProbs(window: samples)
                } catch {
                    AppLog.error(.audioPlayback, "[Sing] guided model run failed: \(error.localizedDescription)")
                    return nil
                }
            }.value
            guard let self else { return }
            self.isScoring = false
            guard self.isActive, self.guidedPhase == .yourTurn, let run, runGeneration == self.generation else { return }
            self.timeline.merge(logProbs: run.values, frames: run.frames, frameSec: run.frameSec, classes: SingPhonemeModel.classes,
                                windowStartSec: windowStart, windowSec: SingPhonemeModel.windowSec, audioStartSec: audioStart)
            let words = Array(self.guidedTurnWords.dropFirst(self.guidedTurnHeardCount))
            guard let earliest = self.timeline.earliestSec,
                  let slice = self.timeline.slice(fromSec: max(earliest, self.guidedTurnAnchorSec ?? earliest),
                                                  toSec: self.timeline.coveredUntilSec) else { return }
            let results = SingPhonemeScorer.wordScores(words: words.map(\.tokens), logProbs: slice.values,
                                                       classes: SingPhonemeModel.classes, firstFrame: 0, lastFrame: slice.frames - 1)
            var stoppedAt: Int?
            for (offset, (word, result)) in zip(words, results).enumerated() {
                guard result.score >= self.strictness.passFraction, let lastFrame = result.lastFrame else {
                    stoppedAt = offset
                    break
                }
                self.verdicts[word.id] = true
                self.guidedPending.remove(word.id)
                self.lastGradedID = word.id
                self.guidedTurnHeardCount += 1
                self.guidedTurnAnchorSec = slice.startSec + Double(lastFrame + 1) * self.timeline.frameSec
            }
            // What the turn so far sounds like, shown under the line and logged against what was expected.
            self.guidedHeard = SingHeardDecoder.kana(logProbs: slice.values, classes: SingPhonemeModel.classes,
                                                     firstFrame: 0, lastFrame: slice.frames - 1)
            let expected = words.map { String($0.tokens.map(SingPhonemeScorer.label)) }
            let stop = stoppedAt.map { "stopped at \($0 + 1)/\(words.count) [\(expected[$0])]" } ?? "all heard"
            AppLog.debug(.audioPlayback, "[Sing] guided line \(index) expected [\(expected.joined(separator: " "))] heard「\(self.guidedHeard)」 scores \(results.map { String(format: "%.2f", $0.score) }.joined(separator: " ")) \(stop)")
            if self.guidedPending.isEmpty { self.closeTurn() }
        }
    }

    // Drops the verdicts of `ids`, so a replayed line starts uncoloured.
    private func clearVerdicts(for ids: Set<Int>) {
        for id in ids {
            verdicts[id] = nil
            heard[id] = nil
        }
        if let last = lastGradedID, ids.contains(last) { lastGradedID = nil }
    }
}
