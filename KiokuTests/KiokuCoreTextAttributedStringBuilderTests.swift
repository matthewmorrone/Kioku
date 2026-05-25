import XCTest
import UIKit
import CoreText
@testable import Kioku

// Guards the contract between segmentation data and the CoreText builder output:
// ruby entries land on kanji runs, color alternation respects toggles, and gate flags
// suppress effects cleanly. These prevent silent feature loss as the renderer evolves.
//
// History note: the builder used to bake CTRubyAnnotation into the attributed string and
// the tests asserted on `kCTRubyAnnotationAttributeName` runs. After the manual-ruby
// migration the builder emits ruby as data (`Output.rubyEntries`) and the view draws it
// in its own pass — assertions now target the entry list directly.
@MainActor
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
            for range in ranges {
                let ns = NSRange(range, in: text)
                if furigana[ns.location] != nil {
                    lengths[ns.location] = ns.length
                }
            }
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
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(output.attributedString.string, "hello")
        // The first run carries .font and .paragraphStyle.
        let attrs = output.attributedString.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.paragraphStyle])
    }

    // MARK: - Ruby entries

    func test_rubyEntry_emittedWhenFuriganaVisibleAndReadingPresent() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        let nsLocation = NSRange(range, in: text).location
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [nsLocation: "ねこ"],
            isFuriganaVisible: true
        )
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(output.rubyEntries.count, 1,
            "Single-kanji segment with reading must produce exactly one ruby entry.")
        XCTAssertEqual(output.rubyEntries.first?.reading, "ねこ")
    }

    func test_rubyEntry_skippedWhenFuriganaInvisible() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        let nsLocation = NSRange(range, in: text).location
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [nsLocation: "ねこ"],
            isFuriganaVisible: false
        )
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertTrue(output.rubyEntries.isEmpty,
            "Furigana-off must not emit ruby entries.")
    }

    func test_rubyEntry_skippedWhenVisualEnhancementsDisabled() throws {
        let text = "猫"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "ねこ"],
            isVisualEnhancementsEnabled: false
        )
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertTrue(output.rubyEntries.isEmpty,
            "Visual-enhancements-off short-circuits the whole segment pass.")
    }

    func test_rubyEntry_okuriganaNotInsideRange() throws {
        // 食べる: ruby "た" attaches only to 食 (location 0, length 1). The data model
        // already projects per-kanji-run readings — the builder just emits each entry
        // at its provided location/length.
        let text = "食べる"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "た"],
            furiganaLength: [0: 1]
        )
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(output.rubyEntries.count, 1, "Expected one ruby entry on 食.")
        let entry = try XCTUnwrap(output.rubyEntries.first)
        XCTAssertEqual(entry.location, 0)
        XCTAssertEqual(entry.length, ("食" as NSString).length,
            "Ruby range must cover only the kanji, not the okurigana べる.")
        XCTAssertEqual(entry.reading, "た")
    }

    func test_rubyEntry_multiRunCompoundGetsPerRunReadings() throws {
        // 抜け殻: two separate kanji runs at locations 0 and 2 (け sits at index 1).
        // The upstream data model already projects per-run readings; the builder
        // surfaces each as its own RubyEntry.
        let text = "抜け殻"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "ぬ", 2: "がら"],
            furiganaLength: [0: 1, 2: 1]
        )
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertEqual(output.rubyEntries.count, 2,
            "Two-run compound must produce two ruby entries, not one spanning okurigana.")
        let locations = Set(output.rubyEntries.map(\.location))
        XCTAssertEqual(locations, [0, 2])
    }

    // Sanity: the attributed string itself should never carry CTRubyAnnotation under the
    // manual-ruby architecture. If this assertion fails, someone re-introduced the
    // CTRubyAnnotation shortcut and `furiganaGap` will be silently broken again.
    func test_attributedString_neverCarriesCTRubyAnnotation() throws {
        let text = "食べる"
        let range = try XCTUnwrap(segmentRange(text, text))
        let inputs = makeInputs(
            text: text,
            segmentRanges: [range],
            furigana: [0: "た"],
            furiganaLength: [0: 1]
        )
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let key = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        var rubyRunCount = 0
        output.attributedString.enumerateAttribute(key, in: NSRange(location: 0, length: output.attributedString.length)) { value, _, _ in
            if value != nil { rubyRunCount += 1 }
        }
        XCTAssertEqual(rubyRunCount, 0,
            "Manual-ruby architecture must not bake CTRubyAnnotation into the attributed string.")
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
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(output.attributedString)
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
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(output.attributedString)
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
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(output.attributedString)
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
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let colors = foregroundColors(output.attributedString)
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
        let output = KiokuCoreTextAttributedStringBuilder.build(inputs)
        XCTAssertTrue(output.rubyEntries.isEmpty)
        let colors = foregroundColors(output.attributedString)
        XCTAssertFalse(colors.contains(.systemRed))
    }
}
