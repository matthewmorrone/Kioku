import XCTest
import UIKit
@testable import Kioku

// Pins the shared RenderGeometry formula. The point of these tests isn't to verify
// arbitrary numbers — it's to make any change to the geometry formula a deliberate, visible
// edit. Both RichTextEditor (edit mode, TextKit 2) and KiokuCoreTextRendererView (view
// mode, CoreText) consume RenderGeometry so character positions match across mode toggles.
// Drift between the two paths used to be ~6pt per line at default settings; if anyone
// reintroduces it, these tests fail loudly with the actual delta.
final class RenderGeometryTests: XCTestCase {

    // Margins that are intentionally fixed (not scaled by typography). Mirrors the legacy
    // RichTextEditor values; touching these reflows every existing note.
    func test_resolve_marginsAreFixed() {
        let g = RenderGeometry.resolve(textSize: 18, userLineSpacing: 0, furiganaGap: 0)
        XCTAssertEqual(g.leftInset, 4)
        XCTAssertEqual(g.bottomInset, 8)
        XCTAssertEqual(g.rightInset, 4)
    }

    // Top inset must include the full ruby reserve (furigana font line height + user gap)
    // plus a 4pt visual margin. Without this term, line 0's ruby would render above the
    // content area's top edge and clip.
    func test_resolve_topInsetIncludesRubyReservePlusMargin() {
        let furiganaFont = UIFont.systemFont(ofSize: 9)
        let g = RenderGeometry.resolve(textSize: 18, userLineSpacing: 0, furiganaGap: 2)
        let expected = furiganaFont.lineHeight + 2 + 4
        XCTAssertEqual(g.topInset, expected, accuracy: 0.01,
            "topInset must equal furiganaFont.lineHeight + furiganaGap + 4 — both renderers depend on this exact formula.")
    }

    // The inter-line gap with the slider at 0 must equal the ruby reserve. Less than that
    // and ruby on line N would overlap line N-1's bottom; more than that adds slack the
    // user didn't ask for.
    func test_resolve_interLineGapIsRubyReserveWhenSliderAtZero() {
        let furiganaFont = UIFont.systemFont(ofSize: 9)
        let g = RenderGeometry.resolve(textSize: 18, userLineSpacing: 0, furiganaGap: 2)
        let expected = furiganaFont.lineHeight + 2
        XCTAssertEqual(g.interLineGap, expected, accuracy: 0.01,
            "interLineGap with userLineSpacing=0 must equal the ruby reserve.")
    }

    // The user's lineSpacing slider adds linearly on top of the ruby reserve. This is what
    // gives the slider the "feel" the user expects: each notch widens line spacing
    // predictably regardless of furigana settings.
    func test_resolve_userLineSpacingIsAdditive() {
        let g0 = RenderGeometry.resolve(textSize: 18, userLineSpacing: 0, furiganaGap: 2)
        let g6 = RenderGeometry.resolve(textSize: 18, userLineSpacing: 6, furiganaGap: 2)
        XCTAssertEqual(g6.interLineGap - g0.interLineGap, 6, accuracy: 0.01,
            "Slider must add linearly to interLineGap.")
    }

    // furiganaGap also adds linearly; this is what makes the user's "ruby distance" knob
    // actually affect inter-line spacing AND the manual ruby's vertical position together
    // — without both moving in lockstep, the ruby would slide relative to its kanji.
    func test_resolve_furiganaGapIsAdditive() {
        let g0 = RenderGeometry.resolve(textSize: 18, userLineSpacing: 0, furiganaGap: 0)
        let g4 = RenderGeometry.resolve(textSize: 18, userLineSpacing: 0, furiganaGap: 4)
        XCTAssertEqual(g4.topInset - g0.topInset, 4, accuracy: 0.01)
        XCTAssertEqual(g4.interLineGap - g0.interLineGap, 4, accuracy: 0.01)
    }

    // Different text sizes scale the ruby reserve via furiganaFont.lineHeight. This test
    // anchors that the formula uses textSize × 0.5 for the furigana font, not a fixed size.
    func test_resolve_scalesWithTextSize() {
        let small = RenderGeometry.resolve(textSize: 12, userLineSpacing: 0, furiganaGap: 0)
        let large = RenderGeometry.resolve(textSize: 24, userLineSpacing: 0, furiganaGap: 0)
        XCTAssertGreaterThan(large.topInset, small.topInset,
            "Larger text size must produce a larger top inset (ruby font scales linearly).")
        XCTAssertGreaterThan(large.interLineGap, small.interLineGap)
    }
}
