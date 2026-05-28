import UIKit

// Single source of truth for the layout geometry both ReadView renderers share. Lives here
// (not on either renderer) so changing the formula doesn't require coordinated edits across
// edit-mode and view-mode code paths — and so a regression where one path drifts from the
// other is impossible by construction.
//
// Invariant this enforces: with ruby spacing OFF, switching between edit and view mode must
// not move any character. The two paths use different layout engines (TextKit 2 in edit
// mode via UITextView, CoreText in view mode via KiokuTextLayoutEngine), but they MUST
// place line origins at the same Y coordinates. They do that by configuring their text
// containers from the same `RenderGeometry` instance.
//
// What's reserved:
//  - `topInset`: space above line 0 large enough to hold one row of furigana (since the
//     manual ruby pass in view mode draws ruby ABOVE its kanji).
//  - `interLineGap`: extra vertical space between consecutive lines large enough for the
//     ruby of line N to fit above the bottom of line N-1, plus the user's tunable gap.
//  - The ruby reserve is included unconditionally, even when furigana is hidden, so toggling
//     the visibility flag doesn't shift any glyph. Slightly more vertical whitespace when
//     furigana is off; consistency wins.
struct RenderGeometry {
    let topInset: CGFloat
    let leftInset: CGFloat
    let bottomInset: CGFloat
    let rightInset: CGFloat
    // Extra space between consecutive lines, on top of each line's typographic height.
    // Both renderers add this between line N-1's bottom and line N's top.
    let interLineGap: CGFloat

    var contentInset: UIEdgeInsets {
        UIEdgeInsets(top: topInset, left: leftInset, bottom: bottomInset, right: rightInset)
    }

    // Resolves the geometry from the typography slider values. The 4pt and 8pt margins
    // mirror what RichTextEditor used historically; touching them changes the look of every
    // existing note, so they're treated as fixed. The ruby-related terms (furigana font
    // line height + the user-configured gap) are what actually scale with text-size.
    static func resolve(
        textSize: Double,
        userLineSpacing: Double,
        furiganaGap: Double,
        // When non-nil, replaces the implicit `textSize * 0.5` furigana font size used
        // to compute the vertical ruby reserve, so enlarging the ruby grows line spacing
        // instead of clipping into the line above. nil preserves legacy behavior.
        furiganaSizeOverride: CGFloat? = nil
    ) -> RenderGeometry {
        let bodyFont = UIFont.systemFont(ofSize: CGFloat(textSize))
        let furiganaFont = UIFont.systemFont(ofSize: furiganaSizeOverride ?? (CGFloat(textSize) * 0.5))
        // Ruby reserve = furigana font's full line height + user's tunable gap. The
        // reserve must accommodate the ruby's ascent + descent (≤ lineHeight) and the
        // visual breathing room the user dialed in via the slider.
        let rubyReserve = furiganaFont.lineHeight + CGFloat(furiganaGap)
        // Top inset for line 0: ruby reserve + a 4pt visual margin so the ruby above
        // line 0 doesn't crowd the very top of the content area. Mirrors the historical
        // edit-mode formula `furiganaFont.lineHeight + furiganaGap + 4`.
        let topInset = rubyReserve + 4
        // Inter-line gap: user's lineSpacing slider + the ruby reserve (so line N's ruby
        // fits above line N-1's bottom). With slider at 0, the gap is exactly the ruby
        // reserve — the minimum that keeps ruby from overlapping the line above it.
        let interLineGap = CGFloat(userLineSpacing) + rubyReserve
        // Suppress unused-binding warning on bodyFont — kept for documentation/future use
        // (any geometry tweak that scales with body font size will reach for it).
        _ = bodyFont
        return RenderGeometry(
            topInset: topInset,
            leftInset: 4,
            bottomInset: 8,
            rightInset: 4,
            interLineGap: interLineGap
        )
    }
}
