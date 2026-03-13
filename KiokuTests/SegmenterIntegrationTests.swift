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

    // Returns deinflection candidates from the shared real deinflector for one surface.
    private func deinflectionCandidates(for surface: String) throws -> Set<String> {
        try sharedResources().deinflector.generateCandidates(for: surface)
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

    // Verifies mixed-script passive stems recover the underlying godan dictionary lemma.
    func testDeinflectorRecoversGodanPassiveLemmaForMixedScriptStem() throws {
        let candidates = try deinflectionCandidates(for: "導かれ")

        XCTAssertTrue(candidates.contains("導く"))
    }

    // Verifies the lattice admits the full passive stem span once the recovery candidate is available.
    func testBuildLatticeUsesPassiveStemRecoveryCandidate() throws {
        let latticeEdges = try buildLattice(for: "導かれ")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "導かれ" && edge.lemma == "導く"
        })
    }

    // Verifies mixed-script desiderative chains recover the underlying verb lemma.
    func testDeinflectorRecoversVerbLemmaForMixedScriptDesiderativeChain() throws {
        let candidates = try deinflectionCandidates(for: "言いたくない")

        XCTAssertTrue(candidates.contains("言う"))
    }

    // Verifies the lattice keeps the full desiderative-negative span once the verb lemma is reachable.
    func testBuildLatticeUsesDesiderativeRecoveryCandidate() throws {
        let latticeEdges = try buildLattice(for: "言いたくない")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "言いたくない" && edge.lemma == "言う"
        })
    }

    // Verifies ichidan negative forms recover their base lemma through deinflection.
    func testDeinflectorRecoversIchidanLemmaForNegativeForm() throws {
        let candidates = try deinflectionCandidates(for: "忘れない")

        XCTAssertTrue(candidates.contains("忘れる"))
    }

    // Verifies potential/ichidan negative forms recover their base lemma through deinflection.
    func testDeinflectorRecoversPotentialLemmaForNegativeForm() throws {
        let candidates = try deinflectionCandidates(for: "できない")

        XCTAssertTrue(candidates.contains("できる"))
    }

    // Verifies the lattice keeps the full ichidan-negative span when lemma recovery succeeds.
    func testBuildLatticeUsesIchidanNegativeRecoveryCandidate() throws {
        let latticeEdges = try buildLattice(for: "忘れない")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "忘れない" && edge.lemma == "忘れる"
        })
    }

    // Verifies the lattice keeps the full potential-negative span when lemma recovery succeeds.
    func testBuildLatticeUsesPotentialNegativeRecoveryCandidate() throws {
        let latticeEdges = try buildLattice(for: "できない")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "できない" && edge.lemma == "できる"
        })
    }

    // Verifies godan te-forms ending in って recover their dictionary lemma.
    func testDeinflectorRecoversGodanLemmaFromTteFormForDeatte() throws {
        let candidates = try deinflectionCandidates(for: "出逢って")

        XCTAssertTrue(candidates.contains("出逢う"))
    }

    // Verifies the lattice keeps the full te-form span when 出逢って resolves through 出逢う.
    func testBuildLatticeUsesGodanTeFormRecoveryCandidateForDeatte() throws {
        let latticeEdges = try buildLattice(for: "出逢って")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "出逢って" && edge.lemma == "出逢う"
        })
    }

    // Verifies adjective adverbial-plus-particle forms recover their base adjective lemma.
    func testDeinflectorRecoversAdjectiveLemmaFromKuDeForm() throws {
        let candidates = try deinflectionCandidates(for: "近くで")

        XCTAssertTrue(candidates.contains("近い"))
    }

    // Verifies adjective nominalized forms recover their base adjective lemma.
    func testDeinflectorRecoversAdjectiveLemmaFromSaNominalization() throws {
        let candidates = try deinflectionCandidates(for: "淋しさ")

        XCTAssertTrue(candidates.contains("淋しい"))
    }

    // Verifies godan causative te-forms recover their dictionary-form lemma.
    func testDeinflectorRecoversGodanLemmaFromCausativeTeForm() throws {
        let candidates = try deinflectionCandidates(for: "覗かせて")

        XCTAssertTrue(candidates.contains("覗く"))
    }

    // Verifies additional adjective nominalized forms recover their base adjective lemma.
    func testDeinflectorRecoversAdjectiveLemmaFromSaNominalizationForAishisa() throws {
        let candidates = try deinflectionCandidates(for: "愛しさ")

        XCTAssertTrue(candidates.contains("愛しい"))
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