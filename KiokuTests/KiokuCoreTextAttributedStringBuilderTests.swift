import XCTest
import UIKit
import CoreText
@testable import Kioku

// Guards the contract between segmentation data and the CoreText attributed string:
// ruby annotations land on kanji runs, color alternation respects toggles, and gate
// flags suppress effects cleanly. These prevent silent feature loss when the experimental
// CoreText path is enabled.
final class KiokuCoreTextAttributedStringBuilderTests: XCTestCase {

    private func segmentRange(_ text: String, _ substring: String) -> Range<String.Index>? {
        text.range(of: substring)
    }

    private func makeInputs(
        text: String = "今日は猫がいる",
        segmentRanges: [Range<String.Index>]? = nil,
        furigana: [Int: String] = [:],
        furiganaLength: [Int: Int] = [:],
        isFuriganaVisible: Bool = true,
        isVisualEnhancementsEnabled: Bool = true,
        isColorAlternationEnabled: Bool = true
    ) -> KiokuCoreTextAttributedStringBuilder.Inputs {
        let ranges = segmentRanges ?? [text.startIndex..<text.endIndex]
        // Default-fill the length dict so callers can pass `furigana` alone and have the
        // length implied as the full segment surface — what most tests want.
        var lengths = furiganaLength
        if lengths.isEmpty && furigana.isEmpty == false {
            let nsText = text as NSString
            for range in ranges {
                let ns = NSRange(range, in: text)
                if furigana[ns.location] != nil {
                    lengths[ns.location] = ns.length
                }
            }
            // Also handle the case where the test points furigana at location 0 spanning the
            // whole text. Falls out of the loop above.
            _ = nsText
        }
        return .init(
            text: text,
            segmentationRanges: ranges,
            furiganaBySegmentLocation: furigana,
            furiganaLengthBySegmentLocation: lengths,
            textSize: 18,
            lineSpacing: 4,
            kerning: 0,
            isVisualEnhancementsEnabled: isVisualEnhancementsEnabled,
            isColorAlternationEnabled: isColorAlternationEnabled,
            isFuriganaVisible: isFuriganaVisible,
            evenSegmentColor: .systemRed,
            oddSegmentColor: .systemBlue
        )
    }

    // Counts NSAttributedString runs carrying a CTRubyAnnotation attribute.
    private func countRubyRuns(_ attributed: NSAttributedString) -> Int {
        var count = 0
        let key = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    // Returns the unique foreground colors applied across the attributed string, in source order.
    private func foregroundColors(_ attributed: NSAttributedString) -> [UIColor] {
        var seen: [UIColor] = []
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let color = value as? UIColor else { return }
            if seen.contains(color) == false {
                seen.append(color)
            }
        }
        return seen
    }

    // MARK: - Base attributes

    func test_baseAttributes_alwaysSetOnEntireString() {
        let inputs = makeInputs(text: "hello")
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(attributed.string, "hello")
        // The first run carries .font and .paragraphStyle.
        let attrs = attributed.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.paragraphStyle])
    }

    // MARK: - Ruby application

    func test_rubyAnnotation_appliedWhenFuriganaVisibleAndReadingPresent() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        let nsLocation = NSRange(range, in: text).location
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [nsLocation: "ねこ"],
            isFuriganaVisible: true
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(countRubyRuns(attributed), 1,
            "Single-kanji segment with reading must produce exactly one ruby run.")
    }

    func test_rubyAnnotation_skippedWhenFuriganaInvisible() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        let nsLocation = NSRange(range, in: text).location
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [nsLocation: "ねこ"],
            isFuriganaVisible: false
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(countRubyRuns(attributed), 0,
            "Furigana-off must not emit ruby annotations.")
    }

    func test_rubyAnnotation_skippedWhenVisualEnhancementsDisabled() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "ねこ"],
            isVisualEnhancementsEnabled: false
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(countRubyRuns(attributed), 0,
            "Visual-enhancements-off short-circuits the whole segment pass.")
    }

    func test_rubyAnnotation_okuriganaNotInsideRuby() throws {
        // 食べる: ruby "た" attaches only to 食 (location 0, length 1). The data model
        // already projects per-kanji-run readings — the builder just attaches each entry
        // at its provided range, so the test verifies the range is honored.
        let text = "食べる"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "た"],
            furiganaLength: [0: 1]
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let key = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        var rubyRange: NSRange = NSRange(location: NSNotFound, length: 0)
        attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if value != nil { rubyRange = range }
        }
        XCTAssertNotEqual(rubyRange.location, NSNotFound, "Expected a ruby run on 食.")
        XCTAssertEqual(rubyRange.location, 0)
        XCTAssertEqual(rubyRange.length, ("食" as NSString).length,
            "Ruby must cover only the kanji, not the okurigana べる.")
    }

    func test_rubyAnnotation_multiRunCompoundGetsPerRunReadings() throws {
        // 抜け殻: two separate kanji runs at locations 0 and 2 (け sits at index 1).
        // The upstream data model already projects per-run readings into furigana
        // entries; the builder attaches each at its range.
        let text = "抜け殻"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "ぬ", 2: "がら"],
            furiganaLength: [0: 1, 2: 1]
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(countRubyRuns(attributed), 2,
            "Two-run compound must produce two CTRubyAnnotation runs, not one spanning okurigana.")
    }

    // MARK: - Color alternation

    func test_colorAlternation_appliesAlternatingColors() throws {
        let text = "猫犬鳥"
        guard
            let r1 = segmentRange(text, "猫"),
            let r2 = segmentRange(text, "犬"),
            let r3 = segmentRange(text, "鳥")
        else { return XCTFail("range-of failed") }
        let inputs = makeInputs(
            text: text,
            segmentRanges: [r1, r2, r3],
            isColorAlternationEnabled: true
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(attributed)
        XCTAssertTrue(colors.contains(.systemRed), "Even-index color must be present.")
        XCTAssertTrue(colors.contains(.systemBlue), "Odd-index color must be present.")
    }

    func test_colorAlternation_skippedWhenDisabled() throws {
        let text = "猫犬"
        guard let r1 = segmentRange(text, "猫"), let r2 = segmentRange(text, "犬") else {
            return XCTFail("range-of failed")
        }
        let inputs = makeInputs(
            text: text,
            segmentRanges: [r1, r2],
            isColorAlternationEnabled: false
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(attributed)
        XCTAssertFalse(colors.contains(.systemRed))
        XCTAssertFalse(colors.contains(.systemBlue))
    }

    // MARK: - Unknown-segment highlight

    func test_unknownHighlight_overridesColorAlternationForFlaggedLocations() throws {
        // Two segments, alternation on, unknown highlight enabled targeting the second
        // segment's location. First segment shows the even color; second shows the
        // unknown color even though alternation would have given it the odd color.
        let text = "猫犬"
        guard let r1 = segmentRange(text, "猫"), let r2 = segmentRange(text, "犬") else {
            return XCTFail("range-of failed")
        }
        let secondLocation = NSRange(r2, in: text).location
        var inputs = makeInputs(
            text: text,
            segmentRanges: [r1, r2],
            isColorAlternationEnabled: true
        )
        inputs.unknownSegmentLocations = [secondLocation]
        inputs.isHighlightUnknownEnabled = true
        inputs.unknownSegmentColor = .systemGreen
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(attributed)
        XCTAssertTrue(colors.contains(.systemGreen),
            "Unknown-flagged segment must use unknown color.")
        XCTAssertFalse(colors.contains(.systemBlue),
            "Odd alternation color must be skipped when unknown highlight overrides it.")
    }

    func test_unknownHighlight_skippedWhenDisabled() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        var inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            isColorAlternationEnabled: true
        )
        inputs.unknownSegmentLocations = [0]
        inputs.isHighlightUnknownEnabled = false
        inputs.unknownSegmentColor = .systemGreen
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(attributed)
        XCTAssertFalse(colors.contains(.systemGreen),
            "Disabled flag must suppress unknown coloring even when locations are populated.")
    }

    func test_visualEnhancementsDisabled_suppressesColorAndRuby() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "ねこ"],
            isVisualEnhancementsEnabled: false,
            isColorAlternationEnabled: true
        )
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(countRubyRuns(attributed), 0)
        let colors = foregroundColors(attributed)
        XCTAssertFalse(colors.contains(.systemRed))
    }
}
