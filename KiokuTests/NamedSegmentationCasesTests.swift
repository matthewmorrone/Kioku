import XCTest
@testable import Kioku

// The named segmentation cases file: one group per decision, each with why it matters.
struct NamedSegmentationCaseFile: Decodable {
    let groups: [NamedSegmentationCaseGroup]
}

// Cases that pin the same decision, and the reason they exist.
struct NamedSegmentationCaseGroup: Decodable {
    let why: String
    let cases: [NamedSegmentationCase]
}

// One text, the segments it must come out as, and (for a one-segment case) the lemma it must resolve to.
struct NamedSegmentationCase: Decodable {
    let text: String
    let segments: [String]
    let lemma: String?
}

// Checks every case in Fixtures/segmentation/named-cases.json against the shipped segmenter. The same
// file is checked in seconds on the Mac by scripts/segmentation-eval/named_cases.py; one file feeds
// both, so a case is added in one place. Cases that should hold but don't are listed in docs/todo.md.
@MainActor
final class NamedSegmentationCasesTests: XCTestCase {

    // Loads the cases file checked in beside the held-out gold.
    private func loadGroups() throws -> [NamedSegmentationCaseGroup] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/segmentation/named-cases.json")
        return try JSONDecoder().decode(NamedSegmentationCaseFile.self, from: Data(contentsOf: url)).groups
    }

    // Segments every case with the default strategy and reports each mismatch with its group's reason,
    // so one run lists every broken case rather than stopping at the first.
    func testNamedCasesHold() throws {
        UserDefaults.standard.removeObject(forKey: SegmenterSettings.strategyKey)
        let segmenter = try TestReadResources.shared().segmenter
        let groups = try loadGroups()
        XCTAssertFalse(groups.isEmpty, "named-cases.json has no groups")
        for group in groups {
            for namedCase in group.cases {
                let got = segmenter.longestMatchEdges(for: namedCase.text).map(\.surface)
                XCTAssertEqual(got, namedCase.segments, "\(namedCase.text) — \(group.why)")
                if let lemma = namedCase.lemma {
                    XCTAssertEqual(segmenter.preferredLemma(for: namedCase.text), lemma, "lemma of \(namedCase.text) — \(group.why)")
                }
            }
        }
    }
}
