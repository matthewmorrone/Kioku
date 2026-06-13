import XCTest
@testable import Kioku

// Regression guard for the About-screen attribution lists. The risk these
// catch isn't subtle: someone moves a Dataset/Library entry around, the
// pasteboard-edit drops one, and the app ships missing an attribution it
// owes by license. These tests don't validate the *content* of each entry —
// just the canonical set's presence.
final class AttributionsTests: XCTestCase {

    func testAllRequiredDatasetsArePresent() {
        let names = Set(Attributions.datasets.map(\.name))
        let required: Set<String> = [
            "JMdict (English)",
            "KANJIDIC2",
            "Tatoeba Sentence Pairs",
            "JPDB Frequency (v2.2)",
            "wordfreq",
            "UniDic Pitch Accent",
            "RADKFILE2 / KRADFILE2",
            "KanjiVG",
            "Tegaki-Zinnia (Japanese)",
        ]
        let missing = required.subtracting(names)
        XCTAssertTrue(missing.isEmpty, "Missing dataset attributions: \(missing.sorted())")
    }

    func testAllRequiredLibrariesArePresent() {
        let names = Set(Attributions.libraries.map(\.name))
        let required: Set<String> = [
            "SwiftWhisper",
            "MeCab",
            "zinnia-swift",
        ]
        let missing = required.subtracting(names)
        XCTAssertTrue(missing.isEmpty, "Missing library attributions: \(missing.sorted())")
    }

    // Each entry must have non-empty fields so the rendered row is never blank.
    func testEveryDatasetEntryIsComplete() {
        for d in Attributions.datasets {
            XCTAssertFalse(d.name.isEmpty, "Dataset name is empty")
            XCTAssertFalse(d.description.isEmpty, "\(d.name): description is empty")
            XCTAssertFalse(d.license.isEmpty, "\(d.name): license is empty")
            XCTAssertTrue(d.sourceURL.hasPrefix("https://"), "\(d.name): sourceURL must be https")
        }
    }

    func testEveryLibraryEntryIsComplete() {
        for l in Attributions.libraries {
            XCTAssertFalse(l.name.isEmpty, "Library name is empty")
            XCTAssertFalse(l.purpose.isEmpty, "\(l.name): purpose is empty")
            XCTAssertTrue(l.sourceURL.hasPrefix("https://"), "\(l.name): sourceURL must be https")
        }
    }

    // Version string falls back gracefully when Info.plist keys are absent —
    // protects against blank "Version " rows in odd build configs.
    func testVersionStringHasFallback() {
        let emptyBundle = Bundle(for: AttributionsTests.self)  // an arbitrary bundle whose
        // Info.plist won't have CFBundleShortVersionString set.
        let v = Attributions.versionString(bundle: emptyBundle)
        XCTAssertFalse(v.isEmpty)
        XCTAssertTrue(v.contains("("), "Version string should always include a build segment")
    }
}
