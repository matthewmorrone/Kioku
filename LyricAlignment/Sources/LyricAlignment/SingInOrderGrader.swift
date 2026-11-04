// SingInOrderGrader.swift
//
// Sing mode's grading of a sung song, with no song clock: the lyric words are taken strictly in
// order from a cursor, and the next few are placed in order across the audio sung since the last
// word that was heard (SingPhonemeScorer.wordScores). A word that is found turns heard and the
// next search starts after it; a word that is not found waits, since it may still be being sung,
// and is marked missed only once enough words after it were heard. The song position is read
// only to put the cursor on the right word after a start or a seek. Pure apart from the timeline
// it is given, so the app and the Mac replay (scripts/sing-replay) run the same code.

import Foundation

/// One word's verdict from SingInOrderGrader.
public struct SingVerdict: Sendable, Equatable {
    /// The word's key, as in SingWordTarget.id.
    public let id: Int
    public let isHeard: Bool
    public let score: Double
    /// What the model heard where the word was looked for, in kana (empty when nothing).
    public let heard: String
}

public final class SingInOrderGrader {
    /// Words searched for at once, and the fewest timeline frames each token needs to fit.
    public var maximumLookahead = 6
    public var framesPerToken = 2
    /// Words that must be heard after a skipped one before it is marked missed.
    public var heardToConfirmMiss = 2
    /// Sounds the model may emit after the last heard word before the word at the cursor is given
    /// up on. Counted in sounds, not seconds, so an instrumental gap never uses it up.
    public var stallSounds = 25

    public let timeline: SingEmissionTimeline
    private let targets: [SingWordTarget]
    private let passFraction: Double
    /// Index in `targets` of the next word to resolve.
    public private(set) var cursor = 0
    /// Timeline second after the last heard word, where the next search starts; nil right after a seek.
    public private(set) var anchorSec: Double?

    public init(targets: [SingWordTarget], passFraction: Double, timeline: SingEmissionTimeline) {
        self.targets = targets
        self.passFraction = passFraction
        self.timeline = timeline
    }

    /// True once every word has a verdict.
    public var isFinished: Bool { cursor >= targets.count }

    /// Puts the cursor on the first word starting at or after `songSec`, drops the buffered
    /// audio, and returns the keys of the words from there on, whose verdicts are void.
    @discardableResult
    public func seek(toSongSec songSec: Double) -> [Int] {
        cursor = targets.firstIndex { $0.startSec >= songSec - 0.3 } ?? targets.count
        anchorSec = nil
        timeline.reset()
        return targets[cursor...].map(\.id)
    }

    /// Resolves as many words from the cursor as the audio on the timeline now allows.
    public func grade() -> [SingVerdict] {
        guard cursor < targets.count, let earliest = timeline.earliestSec,
              let slice = timeline.slice(fromSec: max(earliest, anchorSec ?? earliest), toSec: timeline.coveredUntilSec) else { return [] }
        let budget = slice.frames / framesPerToken
        var upper = cursor, tokenCount = 0
        while upper < targets.count, upper - cursor < maximumLookahead,
              tokenCount + targets[upper].tokens.count <= budget {
            tokenCount += targets[upper].tokens.count
            upper += 1
        }
        guard upper > cursor else { return [] }
        let words = Array(targets[cursor..<upper])
        let classes = timeline.classCount
        let results = SingPhonemeScorer.wordScores(words: words.map(\.tokens), logProbs: slice.values,
                                                   classes: classes, firstFrame: 0, lastFrame: slice.frames - 1)
        let passes = results.map { $0.score >= passFraction && $0.lastFrame != nil }
        var verdicts: [SingVerdict] = []
        // Frame of the slice after the last word resolved this pass, where the next word's audio begins.
        var boundary = 0
        for (offset, word) in words.enumerated() {
            if passes[offset], let lastFrame = results[offset].lastFrame {
                let text = SingHeardDecoder.kana(logProbs: slice.values, classes: classes, firstFrame: boundary, lastFrame: lastFrame)
                verdicts.append(SingVerdict(id: word.id, isHeard: true, score: results[offset].score, heard: text))
                boundary = lastFrame + 1
                cursor += 1
                anchorSec = slice.startSec + Double(boundary) * timeline.frameSec
            } else if passes[(offset + 1)...].filter({ $0 }).count >= heardToConfirmMiss {
                // What was sung instead: the audio between the last heard word and the next one found.
                let nextStart = zip(passes, results).dropFirst(offset + 1).first { $0.0 }?.1.firstFrame
                let text = nextStart.map {
                    SingHeardDecoder.kana(logProbs: slice.values, classes: classes, firstFrame: boundary, lastFrame: $0 - 1)
                } ?? ""
                verdicts.append(SingVerdict(id: word.id, isHeard: false, score: results[offset].score, heard: text))
                cursor += 1
            } else {
                break
            }
        }
        // Nothing resolved: if the singer has clearly sung on past the word at the cursor, it was
        // skipped or can't be heard; mark it missed so it doesn't hold up everything after it.
        if verdicts.isEmpty, soundCount(in: slice) >= stallSounds {
            let word = targets[cursor]
            verdicts.append(SingVerdict(id: word.id, isHeard: false, score: results[0].score, heard: ""))
            cursor += 1
        }
        return verdicts
    }

    // How many frames of `slice` the model puts a sound on rather than blank: the amount sung.
    private func soundCount(in slice: (values: [Float], frames: Int, startSec: Double)) -> Int {
        let classes = timeline.classCount
        var count = 0
        for f in 0..<slice.frames {
            var best = 0
            for c in 1..<classes where slice.values[f * classes + c] > slice.values[f * classes + best] { best = c }
            if best != CTCEmissions.blank { count += 1 }
        }
        return count
    }
}
