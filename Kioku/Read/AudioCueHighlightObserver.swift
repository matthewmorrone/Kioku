import Combine
import SwiftUI

// Zero-size background view that maps AudioPlaybackController cue + time changes to ReadView's
// playbackHighlightRangeOverride and activePlaybackCueIndex bindings.
//
// Granularity drives how tightly the override hugs the active line:
//   - .sentence: the whole cue range (original behavior).
//   - .word:     the segmentationRanges entry containing the current checkpoint's character.
//   - .mora:     the raw checkpoint slice (one character/mora group at a time).
//
// When the active cue has no checkpoints (cue.checkpoints is empty), .word and .mora silently fall
// back to .sentence behavior.
struct AudioCueHighlightObserver: View {
    // Throttles per-tick logging so the log file doesn't fill up.
    nonisolated(unsafe) private static var lastTickLog: Date = .distantPast

    @ObservedObject var controller: AudioPlaybackController
    let cues: [SubtitleCue]
    let highlightRanges: [NSRange?]
    let granularity: LyricsHighlightGranularity
    let segmentationRanges: [Range<String.Index>]
    let noteText: String
    @Binding var playbackHighlightRangeOverride: NSRange?
    @Binding var activePlaybackCueIndex: Int?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let timedCueCount = cues.filter { $0.checkpoints.isEmpty == false }.count
                KaraokeDebugLog.log("observer: onAppear timedCues=\(timedCueCount) hlCount=\(highlightRanges.count) cuesCount=\(cues.count) granularity=\(granularity.rawValue)")
                for (i, cue) in cues.enumerated() {
                    let preview = cue.text.replacingOccurrences(of: "\n", with: "/").prefix(40)
                    KaraokeDebugLog.log("cue[\(i)] idx=\(cue.index) \(cue.startMs)-\(cue.endMs)ms text=\"\(preview)\"")
                }
                updateHighlight(cueIndex: controller.activeCueIndex, currentTimeMs: controller.currentTimeMs, isPlaying: controller.isPlaying)
            }
            .onDisappear {
                KaraokeDebugLog.log("observer: onDisappear")
            }
            .onReceive(
                controller.$activeCueIndex
                    .combineLatest(controller.$currentTimeMs, controller.$isPlaying)
            ) { newIndex, currentTimeMs, isPlaying in
                updateHighlight(cueIndex: newIndex, currentTimeMs: currentTimeMs, isPlaying: isPlaying)
            }
    }

    // Computes the override range from cue + time + granularity + checkpoints.
    private func updateHighlight(cueIndex: Int?, currentTimeMs: Int, isPlaying: Bool) {
        // Unconditional throttled trace so we can tell whether the publisher is firing at all.
        let now = Date()
        if now.timeIntervalSince(Self.lastTickLog) > 1.0 {
            Self.lastTickLog = now
            KaraokeDebugLog.log("observer.tick isPlaying=\(isPlaying) cueIndex=\(cueIndex.map(String.init) ?? "nil") t=\(currentTimeMs)ms hlCount=\(highlightRanges.count)")
        }
        guard isPlaying, let cueIndex, cueIndex < cues.count else {
            playbackHighlightRangeOverride = nil
            activePlaybackCueIndex = nil
            return
        }
        // Prefer the resolved note-text range when we have one — the renderer slices noteText to
        // it. When the resolver couldn't place the cue (whitespace mismatch between SRT and note,
        // late cue past available note lines, etc.), probe noteText for the raw cue text the way
        // LyricsView's activeCueRenderInput does. That keeps the observer's coordinate system in
        // lock-step with the renderer's — without this, the observer would snap segments against
        // a synthetic location=0 range and the band would land on wrong glyphs.
        let cueRange: NSRange = {
            if cueIndex < highlightRanges.count, let resolved = highlightRanges[cueIndex] {
                return resolved
            }
            let cueText = cues[cueIndex].text
            if cueText.isEmpty == false {
                let probe = (noteText as NSString).range(of: cueText)
                if probe.location != NSNotFound { return probe }
            }
            // Truly unaligned — fall back to a cue-local synthetic range. The linear-time
            // fallback will use character-class chunking since noteText segments won't enclose
            // anything in this coordinate system.
            return NSRange(location: 0, length: cueText.utf16.count)
        }()

        let previousCueIndex = activePlaybackCueIndex
        activePlaybackCueIndex = cueIndex

        // Checkpoints ride on the cue at this array position — no index-keyed lookup to desync.
        let checkpoints = cues[cueIndex].checkpoints

        // One log per cue transition is enough — per-tick logging would flood the file.
        if previousCueIndex != cueIndex {
            KaraokeDebugLog.log("observer: cue array=\(cueIndex) idx=\(cues[cueIndex].index) checkpoints=\(checkpoints.count) granularity=\(granularity.rawValue)")
        }

        switch granularity {
        case .sentence:
            playbackHighlightRangeOverride = cueRange
        case .word, .mora:
            // Treat "one checkpoint that covers the entire cue" as "no useful word-level
            // data" — it's what a segments-only TextGrid produces (the binder prefix-matches
            // the full SRT line against the cue text and emits a single full-length
            // checkpoint), and without this guard the observer would sit the band on the
            // first segment forever. Falling through to the elapsed-fraction path slides
            // the band across the cue at constant rate, which is correct in the absence of
            // real word timing. When a proper words-tier TextGrid is present, the binder
            // produces many short checkpoints and this predicate is false.
            let hasUsefulWordCheckpoints: Bool = {
                guard checkpoints.isEmpty == false else { return false }
                if checkpoints.count == 1 {
                    let cp = checkpoints[0]
                    if cp.charOffsetInCue == 0 && cp.charLength >= cueRange.length {
                        return false
                    }
                }
                return true
            }()
            guard hasUsefulWordCheckpoints else {
                // No per-word timing available. We deliberately do NOT fall back to an
                // elapsed-fraction "constant-rate slide" — sung syllables aren't evenly
                // spaced, and a constant-rate band misleads the user into thinking it's
                // tracking the singer when it isn't. Leaving the override nil yields no
                // active-word band and no unplayed-tail dim (LyricsView's
                // `unplayedDimmingLocation` is nil when the override is nil), so the
                // line renders as plain text — honest about what we don't know.
                playbackHighlightRangeOverride = nil
                return
            }
            guard let activeCheckpoint = lastCheckpoint(before: currentTimeMs, in: checkpoints) else {
                playbackHighlightRangeOverride = nil
                return
            }
            let cueLocation = cueRange.location
            let baseRange = NSRange(
                location: cueLocation + activeCheckpoint.charOffsetInCue,
                length: activeCheckpoint.charLength
            )
            // Active word's range only — the band hugs just the current word, and
            // LyricsView reads override.upperBound as the dim-from index so glyphs past the
            // band fade. Played-but-not-current glyphs (before the band) get full alpha,
            // matching Apple-Music-style karaoke: past = bright, present = banded, future
            // = dim.
            if granularity == .word, let segmentRange = enclosingSegmentRange(for: baseRange) {
                playbackHighlightRangeOverride = segmentRange
            } else {
                playbackHighlightRangeOverride = baseRange
            }
        }
    }

    // Returns the latest checkpoint whose timeMs is <= the given playback time, or nil if none.
    private func lastCheckpoint(before timeMs: Int, in checkpoints: [CueCharTiming]) -> CueCharTiming? {
        var match: CueCharTiming? = nil
        for cp in checkpoints {
            if cp.timeMs <= timeMs { match = cp } else { break }
        }
        return match
    }

    // Finds the segmentationRanges entry containing `range.location` in noteText UTF-16 coords.
    // Returns the segment's NSRange in noteText coords, or nil if no segment matches.
    private func enclosingSegmentRange(for range: NSRange) -> NSRange? {
        enclosingSegmentRange(forLocation: range.location)
    }

    // Finds the segmentationRanges entry containing `location` in noteText UTF-16 coords.
    private func enclosingSegmentRange(forLocation targetLocation: Int) -> NSRange? {
        for segment in segmentationRanges {
            let nsSegment = NSRange(segment, in: noteText)
            guard nsSegment.location != NSNotFound else { continue }
            if targetLocation >= nsSegment.location && targetLocation < nsSegment.location + nsSegment.length {
                return nsSegment
            }
            if nsSegment.location > targetLocation { break }
        }
        return nil
    }

    // Returns the start of the character-class run containing `charOffset` in `text`'s UTF-16
    // view. Mirror of `characterClassChunkEnd` — together they give the [start, end) bounds of
    // the active chunk used by the linear-time fallback when noteText segmentation isn't
    // available. Returns 0 if `charOffset` is at or past the text end.
    private func characterClassChunkStart(in text: String, atCharOffset charOffset: Int) -> Int {
        let scalars = Array(text.unicodeScalars)
        var u16Counter = 0
        var scalarIndex = 0
        while scalarIndex < scalars.count && u16Counter < charOffset {
            u16Counter += UTF16.width(scalars[scalarIndex])
            scalarIndex += 1
        }
        guard scalarIndex < scalars.count else { return 0 }
        let startClass = characterClass(of: scalars[scalarIndex])
        var startU16 = u16Counter
        var i = scalarIndex - 1
        while i >= 0, characterClass(of: scalars[i]) == startClass {
            startU16 -= UTF16.width(scalars[i])
            i -= 1
        }
        return max(0, startU16)
    }

    // Returns the end of the character-class run containing `charOffset` in `text`'s UTF-16 view.
    // Used as a last-resort segmentation when the noteText segmentationRanges don't enclose the
    // playback position (synthetic cue range / cue ran past available note lines). Treats kanji,
    // hiragana, katakana, latin, and other as distinct classes so the dim frontier jumps one
    // "word-ish" chunk at a time instead of one mora at a time.
    private func characterClassChunkEnd(in text: String, atCharOffset charOffset: Int) -> Int {
        let utf16 = text.utf16
        let length = utf16.count
        guard charOffset < length else { return length }
        let scalars = Array(text.unicodeScalars)
        // Map the UTF-16 offset to a scalar index by walking scalars and counting UTF-16 units.
        var u16Counter = 0
        var scalarIndex = 0
        while scalarIndex < scalars.count && u16Counter < charOffset {
            u16Counter += UTF16.width(scalars[scalarIndex])
            scalarIndex += 1
        }
        guard scalarIndex < scalars.count else { return length }
        let startClass = characterClass(of: scalars[scalarIndex])
        var endU16 = u16Counter + UTF16.width(scalars[scalarIndex])
        var i = scalarIndex + 1
        while i < scalars.count, characterClass(of: scalars[i]) == startClass {
            endU16 += UTF16.width(scalars[i])
            i += 1
        }
        return min(length, endU16)
    }

    // Coarse character classification for chunking — enough to keep kanji runs together and
    // separate them from kana / latin / punctuation. Not a tokenizer; just a tie-breaker for
    // the linear-time fallback when no real segmentation is available.
    private enum CharClass { case kanji, hiragana, katakana, latin, digit, whitespace, other }

    // Classifies a single scalar into one of the coarse buckets above by checking against
    // the relevant Unicode blocks. Whitespace falls through to a CharacterSet check; anything
    // else (punctuation, symbols) becomes .other so a punctuation run is treated as one chunk.
    private func characterClass(of scalar: Unicode.Scalar) -> CharClass {
        let v = scalar.value
        switch v {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return .kanji
        case 0x3040...0x309F: return .hiragana
        case 0x30A0...0x30FF, 0xFF66...0xFF9F: return .katakana
        case 0x0030...0x0039, 0xFF10...0xFF19: return .digit
        case 0x0041...0x005A, 0x0061...0x007A: return .latin
        default:
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .whitespace }
            return .other
        }
    }
}
