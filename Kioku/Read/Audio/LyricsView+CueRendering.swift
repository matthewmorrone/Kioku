import SwiftUI
import UIKit

// Active-cue rendering helpers — slicing noteText to the active cue, rebasing furigana and
// segmentation ranges into cue-local coordinates, fitting the cue on a single line, and
// computing the alignment-coverage gate that suppresses the unplayed-tail dim when forced
// alignment doesn't reach the cue end. Split out of LyricsView.swift so the main file
// focuses on layout. Pure helpers — no SwiftUI state, no view bodies.
extension LyricsView {
    // Active-cue render input — slices noteText to ONLY the active cue's text and rebases
    // the furigana table to cue-local coordinates. The renderer then has exactly one cue's
    // worth of content, so adjacent cues cannot bleed in. Falls back to the cue's raw text
    // when no noteText range is available (e.g., non-speech cue, alignment didn't resolve).
    struct ActiveCueRenderInput {
        let text: String
        let furiganaBySegmentLocation: [Int: String]
        let furiganaLengthBySegmentLocation: [Int: Int]
        let segmentationRanges: [Range<String.Index>]
    }

    // Builds the sliced render input for the cue at `index`. Strategy:
    //   1. Resolve the cue's NSRange in noteText. Try `highlightRanges[index]` first; fall
    //      back to a substring search if that lookup is nil (non-speech cue, alignment not
    //      yet resolved, etc.) so the cue still renders with full furigana.
    //   2. Filter furigana entries to those whose kanji-run start sits inside the cue and
    //      rebase locations to cue-local UTF-16 coords.
    //   3. Clip each segmentation range to the cue's bounds (don't drop boundary-crossing
    //      segments — that would leave their characters uncolored). Classic CT layout
    //      tolerates clipped sub-segments, so this is safe.
    //   4. If no noteText match exists at all, fall back to the raw cue text without
    //      furigana — the user still sees the line.
    func activeCueRenderInput(for index: Int) -> ActiveCueRenderInput {
        guard index >= 0, index < cues.count else {
            return ActiveCueRenderInput(text: "", furiganaBySegmentLocation: [:], furiganaLengthBySegmentLocation: [:], segmentationRanges: [])
        }

        // Resolve cue range in noteText — prefer the matched highlight range, but also
        // probe by substring so a missing/nil highlight still finds the cue text when it
        // appears verbatim in noteText.
        let resolvedRange: NSRange? = {
            if index < highlightRanges.count, let r = highlightRanges[index] { return r }
            let cueText = cues[index].text
            guard cueText.isEmpty == false else { return nil }
            let probe = (noteText as NSString).range(of: cueText)
            return probe.location == NSNotFound ? nil : probe
        }()

        guard let cueRange = resolvedRange,
              let swiftRange = Range(cueRange, in: noteText) else {
            // Fallback path (non-speech cue, alignment unresolved): use the raw cue text
            // but still clip at the first newline so a multi-line SRT cue only shows the
            // first sung line in the active card — same single-line contract as the
            // resolved path below.
            let raw = cues[index].text
            let fallback = clipAtFirstNewline(raw)
            let wholeRange = fallback.startIndex..<fallback.endIndex
            return ActiveCueRenderInput(
                text: fallback,
                furiganaBySegmentLocation: [:],
                furiganaLengthBySegmentLocation: [:],
                segmentationRanges: fallback.isEmpty ? [] : [wholeRange]
            )
        }

        // Clip at the first newline. The resolver occasionally maps a cue to a noteText
        // range that crosses a line boundary (off-by-N alignment artifact, or a multi-line
        // note section paired with a single-line cue). Without this clip the active card
        // visibly bleeds the next song line in alongside the current one. cueEnd is
        // recomputed against the clipped UTF-16 length so segment/furigana filtering below
        // stays inside the visible slice.
        let rawCueSlice = String(noteText[swiftRange])
        let cueText = clipAtFirstNewline(rawCueSlice)
        let cueStart = cueRange.location
        let cueEnd = cueStart + cueText.utf16.count

        // Furigana: keep entries whose kanji-run UTF-16 start sits inside the cue and
        // rebase the location to the cue substring's coords (so location 0 = first char).
        var rebasedFurigana: [Int: String] = [:]
        var rebasedFuriganaLength: [Int: Int] = [:]
        for (loc, reading) in furiganaBySegmentLocation where loc >= cueStart && loc < cueEnd {
            let rebased = loc - cueStart
            rebasedFurigana[rebased] = reading
            if let length = furiganaLengthBySegmentLocation[loc] {
                rebasedFuriganaLength[rebased] = length
            }
        }

        // Rebase parent segments into cue-local ranges via UTF-16 offsets, so we never
        // cross two String instances with String.Index (which traps in StringUTF16View).
        // Each parent range → NSRange against noteText → clip to [cueStart, cueEnd) →
        // shift by -cueStart → Range<String.Index> against cueText. Boundary-crossing
        // segments are clipped rather than dropped, so every character keeps its color.
        var rebasedSegments: [Range<String.Index>] = []
        if cueText.isEmpty == false {
            let noteNS = noteText as NSString
            for parentRange in segmentationRanges {
                let parentNS = NSRange(parentRange, in: noteText)
                guard parentNS.location != NSNotFound else { continue }
                let segStart = parentNS.location
                let segEnd = parentNS.location + parentNS.length
                let clippedStart = max(segStart, cueStart)
                let clippedEnd = min(segEnd, cueEnd)
                guard clippedEnd > clippedStart, clippedStart >= 0, clippedEnd <= noteNS.length else { continue }
                let localNS = NSRange(location: clippedStart - cueStart, length: clippedEnd - clippedStart)
                if let local = Range(localNS, in: cueText) {
                    rebasedSegments.append(local)
                }
            }
            if rebasedSegments.isEmpty {
                rebasedSegments = [cueText.startIndex..<cueText.endIndex]
            }
        }

        return ActiveCueRenderInput(
            text: cueText,
            furiganaBySegmentLocation: rebasedFurigana,
            furiganaLengthBySegmentLocation: rebasedFuriganaLength,
            segmentationRanges: rebasedSegments
        )
    }

    // Returns a font-size scale factor that fits `text` on a single line within
    // `availableWidth` at the given default font size. Clamped to [0.5, 1.0] so the cue
    // never shrinks below half its default — beyond that, clipping is preferable.
    func activeCueFontScale(text: String, availableWidth: CGFloat) -> CGFloat {
        guard text.isEmpty == false, availableWidth > 0 else { return 1.0 }
        let baseFont = UIFont.systemFont(ofSize: TypographySettings.defaultTextSize)
        let measured = (text as NSString).size(withAttributes: [.font: baseFont]).width
        guard measured > availableWidth else { return 1.0 }
        return max(0.5, min(1.0, availableWidth / measured))
    }

    // Height for the active-cue card — sized to fit one visual line (ruby reserve at top
    // + body line + small bottom margin). Since the renderer now receives only the active
    // cue's text, this height bounds the card; the renderer's contentInset (topInset =
    // rubyReserve + 4) reserves space for ruby above the body line.
    var activeCueRendererHeight: CGFloat {
        let textSize = TypographySettings.defaultTextSize
        let bodyHeight = UIFont.systemFont(ofSize: textSize).lineHeight
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        let rubyReserve = furiganaFont.lineHeight + CGFloat(TypographySettings.defaultFuriganaGap)
        // 4pt top inset + ruby reserve + body line + 4pt bottom margin matches the geometry
        // RenderGeometry produces with userLineSpacing=0.
        return rubyReserve + 4 + bodyHeight + 4
    }

    // Compact height for inactive cue rows and ♪ separators. Drops the ruby reserve since
    // inactive rows are plain Text (no furigana drawn), so reserving that vertical space
    // produces visibly large gaps between rows.
    var inactiveCueRowHeight: CGFloat {
        let textSize = TypographySettings.defaultTextSize
        let bodyHeight = UIFont.systemFont(ofSize: textSize).lineHeight
        return bodyHeight + 4
    }

    // Rebases the noteText-coord override range to cue-local UTF-16 coords for the active-cue
    // renderer. Returns nil when the override is nil (Sentence behavior) or when the range doesn't
    // intersect this cue (cue boundary edge case). Clamps to the cue length so renderer never
    // receives an out-of-bounds NSRange.
    func cueLocalPlaybackHighlightRange(cueOriginInNote: Int, cueLength: Int) -> NSRange? {
        guard let override = playbackHighlightRangeOverride else { return nil }
        let overrideEnd = override.location + override.length
        let cueEnd = cueOriginInNote + cueLength
        let clampedStart = max(override.location, cueOriginInNote)
        let clampedEnd = min(overrideEnd, cueEnd)
        guard clampedEnd > clampedStart else { return nil }
        return NSRange(
            location: clampedStart - cueOriginInNote,
            length: clampedEnd - clampedStart
        )
    }

    // Decides whether the forced-alignment checkpoints for the cue at `displayIndex`
    // cover the line densely enough that dimming the unplayed tail can be done
    // reliably. Returns false (= suppress dim, show whole line at full alpha) when
    // checkpoints are missing or the latest checkpoint stops well short of the cue
    // end — in that case the band would otherwise freeze at a midpoint and chars
    // past it would read as "unplayed" even though they're being sung right now.
    //
    // The 90% threshold is intentionally generous: forced alignment that genuinely
    // covers the line lands with the last checkpoint within a couple characters of
    // cue end (the last word's begin/end). Anything below 90% means we're missing
    // the tail, and "no dim" is a more honest UI than a stuck dim line.
    //
    // Why suppression over linear interpolation: with sparse checkpoints the
    // alignment data itself can't be trusted to localize a frontier, so a clock-
    // based estimate would be guessing. Showing the whole line is the only honest
    // option until alignment improves. Sentence-granularity cues already have
    // override.upperBound == cueLength so they short-circuit this anyway.
    func cueHasReliableDimCoverage(forCueAtIndex displayIndex: Int, cueLength: Int) -> Bool {
        guard displayIndex >= 0, displayIndex < cues.count, cueLength > 0 else { return false }
        let checkpoints = cues[displayIndex].checkpoints
        guard checkpoints.isEmpty == false else { return false }
        let maxEnd = checkpoints.map { $0.charOffsetInCue + $0.charLength }.max() ?? 0
        return Double(maxEnd) >= Double(cueLength) * 0.9
    }

    // Returns `text` truncated at the first newline scalar (\n or \r), or the original
    // string when no newline is present. Used by the active-cue card to enforce a
    // single-song-line contract regardless of multi-line cue text or resolver overshoot.
    func clipAtFirstNewline(_ text: String) -> String {
        if let idx = text.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(text[text.startIndex..<idx])
        }
        return text
    }
}
