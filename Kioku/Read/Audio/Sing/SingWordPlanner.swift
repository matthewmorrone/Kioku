import Foundation
import LyricAlignment

// Turns a song note's aligned cues into the words Sing mode listens for: each word is a
// segment of the note's segmentation inside a sung line, timed by the line's karaoke
// checkpoints, with its phonemes from the same romanizer the aligner reads. Pure, and run off
// the main thread because romanizing a whole song takes a moment.
nonisolated enum SingWordPlanner {
    // Words with fewer phonemes than this (を, a lone vowel) are too short to grade reliably.
    static let minimumTokens = 2
    // A held note can run long; the scorer's 4 s window has to fit the word plus slack.
    static let maximumWordSec = 2.4
    // Longest stretch (lead slack + word + tail slack) one word is graded over. A word is graded
    // once that stretch has passed, so a longer one would put the word's onset at the very front
    // of the 4 s model input, with its lead slack clipped and no audio before it, where the model
    // misses sounds a singer clearly made. 4 s less SingSession's 0.4 s right context, its 0.5 s tick and
    // 0.5 s of audio kept before the stretch. Only the tail slack is trimmed to fit.
    static let maximumGradedSec = 2.6

    // One SingWordTarget per gradeable word, keyed by the word's UTF-16 start in `noteText`.
    // `highlightRanges[i]` is cue i's range in the note (nil → found by substring search, as the
    // lyrics card does).
    static func targets(
        cues: [SubtitleCue],
        noteText: String,
        highlightRanges: [NSRange?],
        segmentRanges: [NSRange],
        romanize: (String) -> [RomanizedSpan]
    ) -> [SingWordTarget] {
        let noteNS = noteText as NSString
        var targets: [SingWordTarget] = []
        for (i, cue) in cues.enumerated() {
            if SubtitleParser.isNonSpeechCue(cue.text.trimmingCharacters(in: .whitespacesAndNewlines)) { continue }
            let resolved: NSRange? = (i < highlightRanges.count ? highlightRanges[i] : nil) ?? {
                let probe = noteNS.range(of: cue.text)
                return probe.location == NSNotFound || cue.text.isEmpty ? nil : probe
            }()
            guard let cueRange = resolved, NSMaxRange(cueRange) <= noteNS.length else { continue }
            // Single sung line, as the active card shows it.
            var line = noteNS.substring(with: cueRange)
            if let cut = line.firstIndex(where: { $0 == "\n" || $0 == "\r" }) { line = String(line[..<cut]) }
            let cueStart = cueRange.location
            let cueEnd = cueStart + line.utf16.count
            let spans = romanize(line)

            // The cue's words, as cue-local [start, end) UTF-16 ranges.
            let words: [(start: Int, end: Int)] = segmentRanges.compactMap { r in
                let s = max(r.location, cueStart), e = min(NSMaxRange(r), cueEnd)
                return e > s ? (s - cueStart, e - cueStart) : nil
            }
            let starts = words.map { startSec(ofWordAt: $0.start, cue: cue, lineLength: line.utf16.count) }
            for (w, word) in words.enumerated() {
                let surface = (line as NSString).substring(with: NSRange(location: word.start, length: word.end - word.start))
                let romaji = particleRomaji[surface].map { [$0] }
                    ?? spans.filter { $0.charOffsetUTF16 >= word.start && $0.charOffsetUTF16 < word.end }.map(\.romaji)
                let tokens = SingPhonemeScorer.tokens(fromRomaji: romaji)
                guard tokens.count >= minimumTokens else { continue }
                let start = starts[w]
                let nextStart = w + 1 < words.count ? starts[w + 1] : Double(cue.endMs) / 1000
                let end = min(max(nextStart, start + 0.1), start + maximumWordSec)
                let lead = w == 0 ? SingPhonemeScorer.lineEdgeLeadSlackSec : SingPhonemeScorer.leadSlackSec
                let tail = w == words.count - 1 ? SingPhonemeScorer.lineEdgeTailSlackSec : SingPhonemeScorer.tailSlackSec
                targets.append(SingWordTarget(
                    id: cueStart + word.start, tokens: tokens, startSec: start, endSec: end,
                    leadSlackSec: lead,
                    tailSlackSec: max(0, min(tail, maximumGradedSec - lead - (end - start)))
                ))
            }
        }
        return targets
    }

    // The particles は and へ are sung "wa" and "e", not as the romanizer spells the kana.
    private static let particleRomaji: [String: String] = ["は": "wa", "へ": "e"]

    // When the word at cue-local `offset` starts: the first karaoke checkpoint at or after it
    // (checkpoints mark mora groups); without checkpoints, its share of the line's duration.
    private static func startSec(ofWordAt offset: Int, cue: SubtitleCue, lineLength: Int) -> Double {
        let sorted = cue.checkpoints.sorted { $0.charOffsetInCue < $1.charOffsetInCue }
        if let hit = sorted.first(where: { $0.charOffsetInCue + $0.charLength > offset }) {
            return Double(hit.timeMs) / 1000
        }
        let share = lineLength > 0 ? Double(offset) / Double(lineLength) : 0
        return (Double(cue.startMs) + share * Double(cue.endMs - cue.startMs)) / 1000
    }
}
