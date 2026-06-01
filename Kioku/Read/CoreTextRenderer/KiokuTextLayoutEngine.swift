import UIKit
import CoreText

// CoreText-based replacement for TextKit 2 in the Read view.
//
// This file is the layout engine: pure value-types + pure computation. Given an attributed
// string and a width, it produces a deterministic list of laid-out lines and exposes per-
// character-range geometry queries. No drawing, no UIView coupling — that lives in
// KiokuCoreTextView.
//
// Coordinate convention: all output Y values are UIKit coordinates (origin top-left, Y grows
// down). CoreText uses bottom-up coordinates internally; the engine flips once at line-build
// time so every consumer sees a single coordinate space.

// One laid-out line. Owns its CTLine plus enough metadata to draw, hit-test, and report rects
// for any sub-range of the source attributed string.
struct KiokuLineLayout {
    let line: CTLine
    // Top-left origin of this line's typographic box in UIKit (Y-down) coordinates, relative
    // to the renderer's content origin.
    var origin: CGPoint
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    let width: CGFloat
    // Range of UTF-16 units in the source attributed string this line covers.
    let stringRange: NSRange

    var height: CGFloat { ascent + descent + leading }
    var baselineY: CGFloat { origin.y + ascent }
    var frame: CGRect { CGRect(x: origin.x, y: origin.y, width: width, height: height) }
}

final class KiokuTextLayoutEngine {

    private(set) var attributedString: NSAttributedString
    private(set) var widthConstraint: CGFloat
    // Inset applied around the laid-out lines. Mirrors UITextView.textContainerInset semantics
    // so callers can keep parity with the existing renderer's positioning math.
    private(set) var contentInset: UIEdgeInsets

    private(set) var lines: [KiokuLineLayout] = []
    // Total content size (line block + content inset). Drives scroll-view contentSize parity.
    private(set) var contentSize: CGSize = .zero

    // Optional inter-line padding added to every line's height. Useful when the attributed
    // string carries CTRubyAnnotation: stock CT typographic bounds reserve only the kanji-row
    // height, so consecutive rubied lines collide. Callers compensate by adding the ruby font
    // height here.
    private(set) var lineSpacing: CGFloat = 0

    // Vertical space reserved ABOVE each line for manually drawn ruby (furigana). The renderer
    // draws ruby in its own draw pass — CoreText's typographic bounds don't include it — so the
    // engine has to leave room above each line's ascent. The reserve is applied uniformly to
    // every line whether or not it actually carries ruby; doing it per-line would re-flow the
    // baseline-to-baseline grid every time a kanji-run with ruby moved between lines, which
    // would cascade through highlight rects and tap geometry. Uniform = predictable.
    //
    // Concretely this is `furiganaFont.lineHeight + furiganaGap` from the caller — the same
    // value FuriganaTextRenderer used as its top inset. Mirrored here so manual ruby has
    // exactly the same vertical envelope as the TK2 path.
    private(set) var topRubyReserve: CGFloat = 0

    // Per-line horizontal origin shift, indexed by line. Used by the wide-ruby line-start
    // inset replacement: instead of feeding the typesetter exclusion paths (which TextKit 2
    // forces to relayout), we lay out at the natural origin and then offset specific lines.
    // The shift moves the line origin and therefore every glyph and every rect query.
    private(set) var lineOriginShifts: [Int: CGFloat] = [:]

    // UTF-16 segment NSRanges, sorted by location. Used to forbid line breaks inside the
    // interior of any segment so multi-character compounds (e.g. 抜け殻) wrap to the next line
    // as an atomic unit instead of being bisected mid-character. Empty = no constraint
    // (legacy behavior; CT picks any character boundary). The TK2 path enforces the same
    // invariant via NSTextLayoutManager's `shouldBreakLineBefore:hyphenating:` delegate;
    // CT has no analogous hook, so the engine post-processes CT's break suggestions instead.
    private var segmentNSRanges: [NSRange] = []

    // When non-nil, the engine is in segment-packed mode: line breaking and per-segment X
    // positioning come from `KiokuSegmentPackedLayout` instead of `CTTypesetterSuggestLineBreak`.
    // The classic `lines` array is still populated (one CTLine per packed line, built from
    // the line's segment range) so existing geometry queries (firstRect, characterIndex, etc.)
    // keep working. Set by the renderer when ruby spacing is on.
    private(set) var segmentPlacements: [KiokuSegmentPackedLayout.Placement] = []
    // Per-line metadata produced by the segment packer. lines[i] still holds a CTLine for
    // line i, but `packedLines[i]` carries the packer's metadata (origin, ascent) so the
    // view can draw per-segment without re-deriving line metrics.
    private(set) var packedLines: [KiokuSegmentPackedLayout.LineLayout] = []
    // True iff the engine is currently using the segment-packed layout. False = classic
    // CT-typesetter layout. Toggled by `setSegmentPackingEnabled`.
    private(set) var isSegmentPackingEnabled: Bool = false
    // Mirrors the renderer's wrapping toggle into the segment-packed code path. Classic CT
    // layout already honors `paragraph.lineBreakMode = .byClipping`; the packer doesn't read
    // paragraph attributes, so we plumb the flag through explicitly. Default true preserves
    // legacy behavior for hosts that don't override it.
    //
    // Rebuilds on change like every other layout-affecting input (setWidthConstraint,
    // setLineSpacing, setSegmentPacking). Without this self-triggered reflow, a wrapping-only
    // change reached the engine via the renderer AFTER setAttributedString had already rebuilt
    // and was ignored by setSegmentPacking's change check — so the packed layout lagged one
    // update behind the flag, showing the stale value at init and needing two toggles to
    // converge. The didSet guards on change to avoid relayout thrash on the renderer's
    // every-pass re-assignment. Initializer-default assignment does not fire didSet, so init()'s
    // own rebuildLayout() remains the single startup reflow.
    var isLineWrappingEnabled: Bool = true {
        didSet {
            guard oldValue != isLineWrappingEnabled else { return }
            rebuildLayout()
        }
    }
    // Per-kanji-run ruby data. Captured here (not just on the renderer) because the engine
    // needs it to measure footprints during segment packing.
    private var furiganaByLocation: [Int: String] = [:]
    private var furiganaLengthByLocation: [Int: Int] = [:]
    // Furigana font used for ruby-width measurement in segment packing.
    private var furiganaFont: UIFont = UIFont.systemFont(ofSize: 9)
    // Body font used for headword-width measurement in segment packing. Captured separately
    // from the attributed string's font attribute so the engine can measure even when the
    // attributed string is empty (e.g. during early init).
    private var bodyFont: UIFont = UIFont.systemFont(ofSize: 18)

    init(
        attributedString: NSAttributedString = NSAttributedString(),
        widthConstraint: CGFloat = 0,
        contentInset: UIEdgeInsets = .zero
    ) {
        self.attributedString = attributedString
        self.widthConstraint = max(0, widthConstraint)
        self.contentInset = contentInset
        rebuildLayout()
    }

    // Updates the source string and rebuilds layout unconditionally. We deliberately do NOT
    // short-circuit on `attributedString.isEqual(to: newValue)` here — that optimization
    // caused a regression where post-split renders kept stale attribute state (segment
    // colors didn't refresh until the renderer was force-remounted via a view/edit toggle).
    // NSAttributedString.isEqual on dynamic UIColor instances or freshly-constructed
    // paragraph styles is fragile, and a missed rebuild = silent staleness. CTTypesetter is
    // fast enough that always rebuilding is the safer default; the perf hit is in the noise.
    func setAttributedString(_ newValue: NSAttributedString) {
        attributedString = newValue
        rebuildLayout()
    }

    // Updates the wrapping width. Triggers relayout if the new width differs by ≥0.5pt; smaller
    // diffs are ignored to avoid relayout thrash on sub-pixel bounds adjustments.
    func setWidthConstraint(_ newValue: CGFloat) {
        let clamped = max(0, newValue)
        guard abs(clamped - widthConstraint) >= 0.5 else { return }
        widthConstraint = clamped
        rebuildLayout()
    }

    // Updates the content inset. Origins shift but no reshaping is required.
    func setContentInset(_ newValue: UIEdgeInsets) {
        guard newValue != contentInset else { return }
        contentInset = newValue
        rebuildLayout()
    }

    // Sets extra inter-line padding. Reflows Y origins; line shaping is unchanged.
    func setLineSpacing(_ newValue: CGFloat) {
        let clamped = max(0, newValue)
        guard abs(clamped - lineSpacing) >= 0.5 else { return }
        lineSpacing = clamped
        rebuildLayout()
    }

    // Sets the per-line space above each line reserved for manually drawn ruby. Reflows Y
    // origins; line shaping is unchanged. Sub-pixel diffs ignored to dodge layout thrash on
    // bouncy sliders.
    func setTopRubyReserve(_ newValue: CGFloat) {
        let clamped = max(0, newValue)
        guard abs(clamped - topRubyReserve) >= 0.5 else { return }
        topRubyReserve = clamped
        rebuildLayout()
    }

    // Sets per-line X-origin shifts. Keys are line indices (0-based, matching `lines`); values
    // are the X delta to apply. Lines absent from the dictionary are not shifted.
    //
    // We avoid relayout entirely — only origins move — but contentSize.width is recomputed.
    func setLineOriginShifts(_ shifts: [Int: CGFloat]) {
        guard shifts != lineOriginShifts else { return }
        lineOriginShifts = shifts
        applyOriginShifts()
    }

    // Sets the segment NSRanges used to forbid mid-segment line breaks. Caller passes the
    // same ranges it uses for color alternation and tap routing — the engine sorts them by
    // location internally so the order callers pass them in doesn't matter. Triggers
    // relayout because line lengths depend on these constraints.
    func setSegmentNSRanges(_ ranges: [NSRange]) {
        let sorted = ranges
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .sorted { $0.location < $1.location }
        guard sorted != segmentNSRanges else { return }
        segmentNSRanges = sorted
        rebuildLayout()
    }

    // Toggles segment-packed layout. When enabled, line breaks and per-segment X positions
    // come from KiokuSegmentPackedLayout (footprint-aware packing) instead of CT's word-wrap.
    // `furiganaByLocation` / `furiganaLengthByLocation` keys are KANJI-RUN UTF-16 locations
    // (matching the renderer's furigana data shape). `bodyFont` / `furiganaFont` are used
    // for footprint measurement.
    func setSegmentPacking(
        enabled: Bool,
        furiganaByLocation: [Int: String] = [:],
        furiganaLengthByLocation: [Int: Int] = [:],
        bodyFont: UIFont = UIFont.systemFont(ofSize: 18),
        furiganaFont: UIFont = UIFont.systemFont(ofSize: 9)
    ) {
        let changed = isSegmentPackingEnabled != enabled
            || self.furiganaByLocation != furiganaByLocation
            || self.furiganaLengthByLocation != furiganaLengthByLocation
            || self.bodyFont != bodyFont
            || self.furiganaFont != furiganaFont
        guard changed else { return }
        isSegmentPackingEnabled = enabled
        self.furiganaByLocation = furiganaByLocation
        self.furiganaLengthByLocation = furiganaLengthByLocation
        self.bodyFont = bodyFont
        self.furiganaFont = furiganaFont
        rebuildLayout()
    }

    // Auto-derives per-line shifts from CTLineGetImageBounds.minX, so a line whose first
    // glyph (or first glyph's ruby annotation) extends past the line origin is shifted right
    // by exactly that amount. This is the correct fix for wide-ruby line-start: it uses CT's
    // own measurement of where the ruby actually renders, so the visible ruby left edge
    // lands precisely at the content inset.
    //
    // Returns the dict for callers who want to inspect / combine with other shifts.
    @discardableResult
    func applyLeftBearingAutoShifts(context: CGContext? = nil) -> [Int: CGFloat] {
        var shifts: [Int: CGFloat] = [:]
        // CTLineGetImageBounds needs a CGContext (it queries graphics state for proper
        // bearing measurement when font hinting / kerning is active). We can pass nil and
        // CT will fall back to a default context, which is good enough for our purposes.
        for (index, line) in lines.enumerated() {
            let bounds = CTLineGetImageBounds(line.line, context)
            // bounds.minX < 0 means the line's first glyph (or its ruby) extends LEFT of
            // the line origin. Shift the line right by that amount so the leftmost rendered
            // pixel sits at the original origin instead.
            if bounds.minX < 0 {
                shifts[index] = ceil(-bounds.minX)
            }
        }
        setLineOriginShifts(shifts)
        return shifts
    }

    // MARK: - Geometry queries

    // Returns the smallest rectangle covering every glyph in the given UTF-16 range. Matches
    // the semantics of UITextView.firstRect(for:) — when the range spans multiple lines, only
    // the first line's portion is returned. Returns nil for empty ranges or out-of-bounds.
    func firstRect(forCharacterRange range: NSRange) -> CGRect? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        // In segment-packed mode, the X position of any character is determined by its
        // owning segment's placement — not by the CTLine's natural typographic offset.
        if isSegmentPackingEnabled {
            return packedFirstRect(forCharacterRange: range)
        }
        guard let line = lines.first(where: { NSIntersectionRange($0.stringRange, range).length > 0 }) else {
            return nil
        }
        let intersection = NSIntersectionRange(line.stringRange, range)
        return rect(in: line, forCharacterRange: intersection)
    }

    // Looks up the rect for `range` using segment-packed placements. The character's owning
    // segment is whichever placement's NSRange contains the range's start; within the
    // segment, sub-ranges get their X by interpolating in the segment's headword, anchored
    // at the segment's centered headword origin (= placement.originX + (footprintWidth -
    // headwordWidth)/2).
    private func packedFirstRect(forCharacterRange range: NSRange) -> CGRect? {
        guard let placement = segmentPlacements.first(where: {
            range.location >= $0.location && range.location < $0.location + $0.length
        }) else { return nil }
        guard let line = packedLines.first(where: { $0.lineIndex == placement.lineIndex }) else { return nil }
        // Build a CTLine for this segment to measure character-level offsets within it.
        let segNSRange = NSRange(location: placement.location, length: placement.length)
        let segAttr = attributedString.attributedSubstring(from: segNSRange)
        let segLine = CTLineCreateWithAttributedString(segAttr as CFAttributedString)
        let localStart = range.location - placement.location
        let localEnd = min(range.location + range.length, placement.location + placement.length) - placement.location
        let xStart = CTLineGetOffsetForStringIndex(segLine, localStart, nil)
        let xEnd = CTLineGetOffsetForStringIndex(segLine, localEnd, nil)
        // Headword's origin = footprint origin + leftOverhang + lineShift. The headword is offset
        // INTO the footprint by leftOverhang so ruby on the leftmost kanji-run sits at
        // the footprint's left edge instead of overhanging into the margin. lineShift mirrors
        // the centering offset the draw passes apply, so geometry queries match what's drawn.
        let lineShift = lineOriginShifts[placement.lineIndex] ?? 0
        let headwordOriginX = placement.originX + placement.leftOverhang + lineShift
        return CGRect(
            x: headwordOriginX + min(xStart, xEnd),
            y: line.originY,
            width: abs(xEnd - xStart),
            height: line.height
        )
    }

    // Returns the rectangle covering the given character range within the supplied line. The
    // range must be a subset of line.stringRange (caller's responsibility to clip).
    func rect(in line: KiokuLineLayout, forCharacterRange range: NSRange) -> CGRect {
        let startX = CTLineGetOffsetForStringIndex(line.line, range.location, nil)
        let endX = CTLineGetOffsetForStringIndex(line.line, range.location + range.length, nil)
        let leftX = min(startX, endX)
        let rightX = max(startX, endX)
        return CGRect(
            x: line.origin.x + leftX,
            y: line.origin.y,
            width: rightX - leftX,
            height: line.height
        )
    }

    // Returns the index of the line containing the given UTF-16 character index, or nil if
    // the index is out of bounds. The lookup is linear in line count, which is fine for the
    // small note sizes Kioku targets; switch to binary search if profiling shows hot spots.
    func lineIndex(forCharacterIndex characterIndex: Int) -> Int? {
        guard characterIndex >= 0 else { return nil }
        return lines.firstIndex { line in
            characterIndex >= line.stringRange.location &&
            characterIndex < line.stringRange.location + line.stringRange.length
        }
    }

    // Returns one rect per line spanned by the range. Empty array for out-of-bounds or empty
    // ranges. This is the multi-line analogue of `firstRect(forCharacterRange:)` and is what
    // segment overlays and highlight bands use for ranges that wrap.
    func boundingRects(forCharacterRange range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        // In segment-packed mode the line's CTLine has CT's natural-advance X positions,
        // NOT the packer's segment-footprint X positions — so deriving rects via
        // `rect(in: line:)` would paint highlight bands at the wrong horizontal place
        // (compressed toward the line's left edge). Route through packed placements
        // instead so band X positions match what the user actually sees on screen.
        if isSegmentPackingEnabled {
            return packedBoundingRects(forCharacterRange: range)
        }
        return lines.compactMap { line in
            let intersection = NSIntersectionRange(line.stringRange, range)
            guard intersection.length > 0 else { return nil }
            return rect(in: line, forCharacterRange: intersection)
        }
    }

    // Packed-mode rect lookup: walks every segment placement that intersects `range` and
    // emits one rect per intersection using the segment's footprint-aware origin. Output
    // matches `firstRect`'s coordinate system so highlight bands sit exactly where the
    // segment renders.
    //
    // The rect's X-range starts from the intersected headword glyph advance and is then
    // widened to cover any ruby annotation whose kanji-run intersects `range`. Without
    // that expansion, a band over a kanji with wider furigana (e.g. うつくしい over 美しい)
    // is only as wide as the kanji glyph; the ruby above sits unhighlighted past either
    // end. Including ruby in the X envelope matches the user-visible "this word is
    // highlighted" semantic — the furigana is part of the word.
    private func packedBoundingRects(forCharacterRange range: NSRange) -> [CGRect] {
        var rects: [CGRect] = []
        for placement in segmentPlacements {
            let segRange = NSRange(location: placement.location, length: placement.length)
            let intersection = NSIntersectionRange(segRange, range)
            guard intersection.length > 0 else { continue }
            guard let line = packedLines.first(where: { $0.lineIndex == placement.lineIndex }) else { continue }
            let segAttr = attributedString.attributedSubstring(from: segRange)
            let segLine = CTLineCreateWithAttributedString(segAttr as CFAttributedString)
            let localStart = intersection.location - placement.location
            let localEnd = localStart + intersection.length
            let xStart = CGFloat(CTLineGetOffsetForStringIndex(segLine, localStart, nil))
            let xEnd = CGFloat(CTLineGetOffsetForStringIndex(segLine, localEnd, nil))
            var minX = min(xStart, xEnd)
            var maxX = max(xStart, xEnd)

            // Extend the envelope by any ruby annotation whose kanji-run overlaps the
            // highlight range. Ruby X positions are computed in the same segment-local
            // CTLine coordinate system as the headword glyph positions, so they can be
            // mixed into the same min/max without further translation.
            for (rubyLoc, reading) in furiganaByLocation {
                guard NSLocationInRange(rubyLoc, segRange) else { continue }
                guard let rubyLen = furiganaLengthByLocation[rubyLoc], rubyLen > 0 else { continue }
                guard rubyLoc + rubyLen <= placement.location + placement.length else { continue }
                let rubyRange = NSRange(location: rubyLoc, length: rubyLen)
                guard NSIntersectionRange(rubyRange, range).length > 0 else { continue }
                let rubyLocalStart = rubyLoc - placement.location
                let rubyLocalEnd = rubyLocalStart + rubyLen
                let kanjiXStart = CGFloat(CTLineGetOffsetForStringIndex(segLine, rubyLocalStart, nil))
                let kanjiXEnd = CGFloat(CTLineGetOffsetForStringIndex(segLine, rubyLocalEnd, nil))
                let kanjiCenter = (kanjiXStart + kanjiXEnd) / 2
                let rubyW = ceil((reading as NSString).size(withAttributes: [.font: furiganaFont]).width)
                minX = min(minX, kanjiCenter - rubyW / 2)
                maxX = max(maxX, kanjiCenter + rubyW / 2)
            }

            // Mirror the centering shift the draw passes apply so highlight-band rects
            // stay aligned with the glyphs they're meant to underline.
            let lineShift = lineOriginShifts[placement.lineIndex] ?? 0
            let headwordOriginX = placement.originX + placement.leftOverhang + lineShift
            rects.append(CGRect(
                x: headwordOriginX + minX,
                y: line.originY,
                width: maxX - minX,
                height: line.height
            ))
        }
        return rects
    }

    // Tap target padding. The character resolver applies these symmetrically around each
    // line's typographic box: 6pt horizontal soaks up segment-boundary slop on dense kana
    // lines without re-introducing "tap empty margin, snap to the nearest word"; 6pt vertical
    // catches taps that fall in the inter-line gap between consecutive lines. Both kept well
    // under half the minimum inter-line distance so adjacent-line slop bands can't overlap.
    private let hitTestHorizontalSlop: CGFloat = 6
    private let hitTestVerticalSlop: CGFloat = 6

    // Returns the line whose typographic box contains `y`, or the nearest one within
    // `hitTestVerticalSlop`. Generic over the line-shaped collection because both the
    // standard `lines` and the packed `packedLines` need the same selection logic.
    private func nearestLine<Line>(
        toY y: CGFloat,
        in lines: [Line],
        lineY: (Line) -> CGFloat,
        lineHeight: (Line) -> CGFloat
    ) -> Line? {
        if let containing = lines.first(where: { y >= lineY($0) && y < lineY($0) + lineHeight($0) }) {
            return containing
        }
        var bestLine: Line?
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for line in lines {
            let top = lineY(line)
            let bottom = top + lineHeight(line)
            let distance: CGFloat = y < top ? (top - y) : (y - bottom)
            if distance < bestDistance {
                bestDistance = distance
                bestLine = line
            }
        }
        return bestDistance <= hitTestVerticalSlop ? bestLine : nil
    }

    // Maps a point in renderer coordinates to its UTF-16 character index. Returns nil when
    // the point falls outside the laid-out content area OR past a line's actual content
    // (right margin, indent area, etc.) — without this strict X clamp, CTLineGetStringIndex
    // ForPosition would return the nearest character on the line for taps in empty space,
    // which makes selection-clearing impossible: the host can't tell "tapped a word" from
    // "tapped past the last word."
    //
    // X-axis slop absorbs sub-pixel boundary slop on the segment boundary gesture without
    // re-introducing the "clicks empty space, selects nearest word" bug. Y-axis slop catches
    // taps that land in the inter-line gap, snapping them to the nearest line — without it,
    // every tap between lines silently fails and the user has to re-aim.
    func characterIndex(at point: CGPoint) -> Int? {
        // Segment-packed mode: hit-test against placements directly. Y picks the line, X
        // picks the placement whose footprint contains the point.
        if isSegmentPackingEnabled {
            return packedCharacterIndex(at: point)
        }
        // Y: prefer a line whose typographic box contains the point; otherwise accept the
        // closest line if the tap is within `hitTestVerticalSlop` of its top/bottom edge.
        // Anything farther stays nil so taps far above/below the text don't select.
        guard let line = nearestLine(toY: point.y, in: lines, lineY: { $0.origin.y }, lineHeight: { $0.height }) else {
            return nil
        }
        // X must fall inside the line's actual content rectangle (origin → origin + width),
        // with a small slop on either side. CTLineGetStringIndexForPosition will happily
        // return the last-glyph index for a point well past the right edge; the clamp blocks
        // that. We also clamp the point's X into the line interior before forwarding so a
        // tap inside the slop band still resolves to the actual edge character.
        let minX = line.origin.x - hitTestHorizontalSlop
        let maxX = line.origin.x + line.width + hitTestHorizontalSlop
        guard point.x >= minX, point.x <= maxX else { return nil }
        let clampedX = min(max(point.x, line.origin.x), line.origin.x + line.width)
        let localPoint = CGPoint(x: clampedX - line.origin.x, y: 0)
        let index = CTLineGetStringIndexForPosition(line.line, localPoint)
        guard index != kCFNotFound else { return nil }
        return index
    }

    // Segment-packed hit test. Picks the line whose Y range contains `point.y`, then the
    // placement whose footprint X range contains `point.x`. Within the segment, returns
    // the character index at the local X via CTLineGetStringIndexForPosition.
    private func packedCharacterIndex(at point: CGPoint) -> Int? {
        guard let line = nearestLine(toY: point.y, in: packedLines, lineY: { $0.originY }, lineHeight: { $0.height }) else {
            return nil
        }
        let placementsOnLine = segmentPlacements.filter { $0.lineIndex == line.lineIndex }
        guard let placement = placementsOnLine.first(where: {
            point.x >= $0.originX - hitTestHorizontalSlop && point.x < $0.originX + $0.footprintWidth + hitTestHorizontalSlop
        }) else { return nil }
        // Translate point.x into the segment's headword-local X. Headword sits offset
        // INTO the footprint by leftOverhang so ruby on the leftmost kanji fits.
        let headwordOriginX = placement.originX + placement.leftOverhang
        let segNSRange = NSRange(location: placement.location, length: placement.length)
        let segAttr = attributedString.attributedSubstring(from: segNSRange)
        let segLine = CTLineCreateWithAttributedString(segAttr as CFAttributedString)
        let localPoint = CGPoint(x: point.x - headwordOriginX, y: 0)
        let localIndex = CTLineGetStringIndexForPosition(segLine, localPoint)
        guard localIndex != kCFNotFound else { return placement.location }
        return placement.location + min(localIndex, placement.length - 1)
    }

    // MARK: - Layout

    private func rebuildLayout() {
        lines.removeAll(keepingCapacity: true)
        segmentPlacements.removeAll(keepingCapacity: true)
        packedLines.removeAll(keepingCapacity: true)

        let availableWidth = max(0, widthConstraint - contentInset.left - contentInset.right)
        guard attributedString.length > 0, availableWidth > 0 else {
            contentSize = CGSize(
                width: contentInset.left + contentInset.right,
                height: contentInset.top + contentInset.bottom
            )
            return
        }

        // Segment-packed mode: bypass CT's word-wrap and pack segments by max(headword,
        // ruby) footprint. Driven by the renderer when ruby spacing is on.
        if isSegmentPackingEnabled && segmentNSRanges.isEmpty == false {
            rebuildLayoutSegmentPacked(availableWidth: availableWidth)
            return
        }

        let typesetter = CTTypesetterCreateWithAttributedString(attributedString)
        let totalLength = attributedString.length
        var startIndex = 0
        var penY: CGFloat = contentInset.top

        while startIndex < totalLength {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, startIndex, Double(availableWidth))
            guard suggested > 0 else { break }
            // Walk the suggestion back to the nearest segment boundary if it landed inside
            // a segment's interior. Mirrors what TK2's `shouldBreakLineBefore:` delegate
            // does at typeset time — TK2 vetoes the break, CT doesn't have a veto API, so
            // we shorten the line ourselves.
            let lineLength = adjustedLineLength(
                startingAt: startIndex,
                suggestedLineLength: suggested,
                totalLength: totalLength
            )

            let stringRange = NSRange(location: startIndex, length: lineLength)
            let line = CTTypesetterCreateLine(typesetter, CFRangeMake(startIndex, lineLength))

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

            // Reserve ruby room ABOVE this line by advancing the pen before placing it.
            // Includes the first line — the top inset already comes from contentInset.top,
            // and topRubyReserve adds the per-line ruby band on top of that. Mirrors TK2's
            // top inset math (`furiganaFont.lineHeight + furiganaGap + 4`) where the `+ 4`
            // is supplied by the caller via contentInset.top.
            penY += topRubyReserve

            let layout = KiokuLineLayout(
                line: line,
                origin: CGPoint(x: contentInset.left, y: penY),
                ascent: ascent,
                descent: descent,
                leading: leading,
                width: lineWidth,
                stringRange: stringRange
            )
            lines.append(layout)

            penY += layout.height + lineSpacing
            startIndex += lineLength
        }

        applyOriginShifts()

        let lineBlockHeight = (lines.last.map { $0.origin.y + $0.height } ?? contentInset.top) - contentInset.top
        contentSize = CGSize(
            width: maxLineRightEdge() + contentInset.right,
            height: contentInset.top + lineBlockHeight + contentInset.bottom
        )
    }

    // Applies the current `lineOriginShifts` map to the existing `lines`. Called both after
    // a fresh layout (to re-apply known shifts) and from `setLineOriginShifts` (no relayout).
    private func applyOriginShifts() {
        for index in lines.indices {
            let baseX = contentInset.left
            let shift = lineOriginShifts[index] ?? 0
            lines[index].origin.x = baseX + shift
        }
        contentSize.width = maxLineRightEdge() + contentInset.right
    }

    // Right edge of the widest laid-out line, used to compute contentSize.width.
    private func maxLineRightEdge() -> CGFloat {
        lines.map { $0.origin.x + $0.width }.max() ?? contentInset.left
    }

    // Builds the layout via the footprint-aware segment packer instead of CT's word-wrap.
    // Each placed segment also gets a CTLine (built from its substring) stored in `lines`
    // for backward compat with consumers that walk `lines` (debug overlay, accessibility).
    // Geometry queries (firstRect, characterIndex) check `isSegmentPackingEnabled` and
    // route through `segmentPlacements` when in this mode.
    private func rebuildLayoutSegmentPacked(availableWidth: CGFloat) {
        let result = KiokuSegmentPackedLayout.pack(.init(
            attributedString: attributedString,
            segmentNSRanges: segmentNSRanges,
            furiganaByLocation: furiganaByLocation,
            furiganaLengthByLocation: furiganaLengthByLocation,
            baseFont: bodyFont,
            furiganaFont: furiganaFont,
            availableWidth: availableWidth,
            topInset: contentInset.top + topRubyReserve,
            interLineGap: lineSpacing + topRubyReserve,
            leftInset: contentInset.left,
            isLineWrappingEnabled: isLineWrappingEnabled
        ))
        segmentPlacements = result.placements
        packedLines = result.lines
        // Populate `lines` so existing consumers (debug overlay, accessibility per-line
        // reads) keep working. One CTLine per packed line; the line's stringRange covers
        // its segments' UTF-16 union. For drawing we don't actually use these CTLines —
        // the view branches on isSegmentPackingEnabled and walks placements instead — but
        // the `lines` array is still load-bearing for non-drawing geometry.
        for packedLine in result.lines {
            let segmentsOnLine = result.placements.filter { $0.lineIndex == packedLine.lineIndex }
            guard let first = segmentsOnLine.first, let last = segmentsOnLine.last else { continue }
            let stringRange = NSRange(
                location: first.location,
                length: (last.location + last.length) - first.location
            )
            let line = CTLineCreateWithAttributedString(
                attributedString.attributedSubstring(from: stringRange) as CFAttributedString
            )
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            lines.append(KiokuLineLayout(
                line: line,
                origin: CGPoint(x: contentInset.left, y: packedLine.originY),
                ascent: ascent,
                descent: descent,
                leading: leading,
                width: (last.originX + last.footprintWidth) - first.originX,
                stringRange: stringRange
            ))
        }
        applyOriginShifts()
        let lineBlockHeight = result.contentSize.height - contentInset.top
        contentSize = CGSize(
            width: max(result.contentSize.width, contentInset.left) + contentInset.right,
            height: contentInset.top + lineBlockHeight + contentInset.bottom
        )
    }

    // Walks a CT line-break suggestion back to the nearest segment boundary if the suggestion
    // would land inside a segment's interior. Returns the original suggestion when:
    //   - no segment ranges are configured (legacy mode)
    //   - the suggested break offset is at a segment boundary (or end-of-text)
    //   - the segment containing the break starts AT or BEFORE this line's startIndex (the
    //     segment is wider than the available line; we have to break inside it)
    //
    // The post-process pattern mirrors how TK2's `shouldBreakLineBefore:` worked: CT proposes
    // a break, and the engine vetoes by shortening to the previous segment start. We don't
    // need to defend against pathological inputs (zero-length segments, NSNotFound, overlap)
    // because `setSegmentNSRanges` filters and sorts at write time.
    private func adjustedLineLength(
        startingAt startIndex: Int,
        suggestedLineLength: Int,
        totalLength: Int
    ) -> Int {
        guard segmentNSRanges.isEmpty == false else { return suggestedLineLength }
        let candidateBreakOffset = startIndex + suggestedLineLength
        // End-of-text breaks are always fine.
        if candidateBreakOffset >= totalLength { return suggestedLineLength }
        // Find the segment containing the break OFFSET in its interior. NSLocationInRange
        // matches [location, location+length); we want strict-interior so the boundary
        // (offset == segment.location) is allowed.
        guard let containing = segmentNSRanges.first(where: { range in
            candidateBreakOffset > range.location && candidateBreakOffset < range.location + range.length
        }) else {
            return suggestedLineLength
        }
        // Walk back to the segment's start. The line should end where this segment begins,
        // so the segment wraps to the next line as one piece.
        let adjusted = containing.location - startIndex
        // If the segment starts at or before this line's startIndex, the segment is wider
        // than the available width. We can't avoid breaking inside it without dropping
        // characters or producing a zero-length line; honor CT's break instead.
        guard adjusted > 0 else { return suggestedLineLength }
        return adjusted
    }
}
