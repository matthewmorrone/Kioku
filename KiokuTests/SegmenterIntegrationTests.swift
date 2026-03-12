import XCTest
@testable import Kioku

// Exercises the real segmenter pipeline against a few small strings without rebuilding the trie per test.
final class SegmenterIntegrationTests: XCTestCase {

    // Returns the shared test harness so each test uses the same dictionary-backed pipeline instance.
    private func sharedResources() throws -> TestReadResources {
        try TestReadResources.shared()
    }

    // Builds the real lattice for a small input string using the shared segmenter pipeline.
    private func buildLattice(for text: String) throws -> [LatticeEdge] {
        try sharedResources().segmenter.buildLattice(for: text)
    }

    // Builds human-readable inclusion lines for the full real lattice in source order using the segmenter's debug summary.
    private func inclusionLines(for text: String) throws -> [String] {
        let resources = try sharedResources()
        return resources.segmenter.buildLattice(for: text)
            .sorted { lhs, rhs in
                let lhsStart = text.distance(from: text.startIndex, to: lhs.start)
                let rhsStart = text.distance(from: text.startIndex, to: rhs.start)
                if lhsStart != rhsStart {
                    return lhsStart < rhsStart
                }

                let lhsEnd = text.distance(from: text.startIndex, to: lhs.end)
                let rhsEnd = text.distance(from: text.startIndex, to: rhs.end)
                if lhsEnd != rhsEnd {
                    return lhsEnd < rhsEnd
                }

                if lhs.surface != rhs.surface {
                    return lhs.surface < rhs.surface
                }

                return lhs.lemma < rhs.lemma
            }
            .map { edge in
                let startOffset = text.distance(from: text.startIndex, to: edge.start)
                let endOffset = text.distance(from: text.startIndex, to: edge.end)
                let summary = resources.segmenter.debugResolutionSummary(for: edge.surface, lemma: edge.lemma)
                return "\(startOffset)->\(endOffset) \(edge.surface) [lemma: \(edge.lemma)] [\(summary)]"
            }
    }

    // Resolves the repository root so targeted tests can persist inspection output under tmp/.
    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // Verifies the shared harness does not rebuild a second trie instance for subsequent tests.
    func testSharedHarnessCachesResources() throws {
        let firstResources = try TestReadResources.shared()
        let secondResources = try TestReadResources.shared()

        XCTAssertEqual(ObjectIdentifier(firstResources), ObjectIdentifier(secondResources))
    }

    // Verifies a simple exact dictionary span and its shorter alternatives coexist in the lattice.
    func testBuildLatticeIncludesExactParticleSpan() throws {
        let latticeEdges = try buildLattice(for: "には")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "には" && edge.lemma == "には"
        })
        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "に" && edge.lemma == "に"
        })
        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "は" && edge.lemma == "は"
        })
    }

    // Verifies katakana normalization can admit a surface through the real deinflector pipeline.
    func testBuildLatticeUsesKatakanaNormalizationCandidate() throws {
        let latticeEdges = try buildLattice(for: "スマイ")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "スマイ" && edge.lemma == "すまい"
        })
    }

    // Verifies compound-verb recovery still contributes alternate lemmas through the shared deinflector path.
    func testBuildLatticeUsesCompoundVerbRecoveryCandidate() throws {
        let latticeEdges = try buildLattice(for: "さがしつづける")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "さがしつづける" && edge.lemma == "さがす"
        })
    }

    // Prints and verifies the real inclusion results for the katakana-heavy surface we have been inspecting.
    func testReportLatticeInclusionResultsForExaminedSurface() throws {
        let examinedText = "かなしみがいまセーラースマイル"
        let lines = try inclusionLines(for: examinedText)
        let reportURL = repositoryRootURL()
            .appendingPathComponent("tmp")
            .appendingPathComponent("examined-surface-lattice-report.txt")

        print("LATTICE INCLUSION REPORT \(examinedText)")
        for line in lines {
            print(line)
        }

        let report = (["LATTICE INCLUSION REPORT \(examinedText)"] + lines).joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(lines.contains { line in
            line.contains("ス [lemma: す]")
        })
        XCTAssertTrue(lines.contains { line in
            line.contains("スマイ [lemma: すまい]")
        })
        XCTAssertTrue(lines.contains { line in
            line.contains("イル [lemma: いる]")
        })
        XCTAssertTrue(lines.contains { line in
            line.contains("ル [lemma: る]")
        })
    }
}