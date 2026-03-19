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

                return lhs.surface < rhs.surface
            }
            .map { edge in
                let startOffset = text.distance(from: text.startIndex, to: edge.start)
                let endOffset = text.distance(from: text.startIndex, to: edge.end)
                let derivedLemma = resources.segmenter.preferredLemma(for: edge.surface) ?? edge.surface
                let summary = resources.segmenter.debugResolutionSummary(for: edge.surface, lemma: derivedLemma)
                return "\(startOffset)->\(endOffset) \(edge.surface) [lemma: \(derivedLemma)] [\(summary)]"
            }
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
            edge.surface == "には"
        })
        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "に"
        })
        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "は"
        })
    }

    // Verifies katakana normalization can admit a surface through the real deinflector pipeline.
    func testBuildLatticeUsesKatakanaNormalizationCandidate() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "スマイ")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "スマイ" && resources.segmenter.preferredLemma(for: edge.surface) == "すまい"
        })
    }

    // Verifies compound-verb recovery still contributes alternate lemmas through the shared deinflector path.
    func testBuildLatticeUsesCompoundVerbRecoveryCandidate() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "さがしつづける")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "さがしつづける" && resources.segmenter.preferredLemma(for: edge.surface) == "さがす"
        })
    }

    // Verifies mixed-script passive stems recover the underlying godan dictionary lemma.
    func testDeinflectorRecoversGodanPassiveLemmaForMixedScriptStem() throws {
        let candidates = try deinflectionCandidates(for: "導かれ")

        XCTAssertTrue(candidates.contains("導く"))
    }

    // Verifies the lattice admits the full passive stem span once the recovery candidate is available.
    func testBuildLatticeUsesPassiveStemRecoveryCandidate() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "導かれ")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "導かれ" && resources.segmenter.preferredLemma(for: edge.surface) == "導く"
        })
    }

    // Verifies mixed-script desiderative chains recover the underlying verb lemma.
    func testDeinflectorRecoversVerbLemmaForMixedScriptDesiderativeChain() throws {
        let candidates = try deinflectionCandidates(for: "言いたくない")

        XCTAssertTrue(candidates.contains("言う"))
    }

    // Verifies the lattice keeps the full desiderative-negative span once the verb lemma is reachable.
    func testBuildLatticeUsesDesiderativeRecoveryCandidate() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "言いたくない")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "言いたくない" && resources.segmenter.preferredLemma(for: edge.surface) == "言う"
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
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "忘れない")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "忘れない" && resources.segmenter.preferredLemma(for: edge.surface) == "忘れる"
        })
    }

    // Verifies the lattice keeps the full potential-negative span when lemma recovery succeeds.
    func testBuildLatticeUsesPotentialNegativeRecoveryCandidate() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "できない")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "できない" && resources.segmenter.preferredLemma(for: edge.surface) == "できる"
        })
    }

    // Verifies godan te-forms ending in って recover their dictionary lemma.
    func testDeinflectorRecoversGodanLemmaFromTteFormForDeatte() throws {
        let candidates = try deinflectionCandidates(for: "出逢って")

        XCTAssertTrue(candidates.contains("出逢う"))
    }

    // Verifies the lattice keeps the full te-form span when 出逢って resolves through 出逢う.
    func testBuildLatticeUsesGodanTeFormRecoveryCandidateForDeatte() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "出逢って")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "出逢って" && resources.segmenter.preferredLemma(for: edge.surface) == "出逢う"
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

    // Verifies v5 す-verb benefactive (てくれる) chains recover their dictionary lemma in one step.
    func testDeinflectorRecoversBenefactiveVerbLemmaForSuVerb() throws {
        let candidates = try deinflectionCandidates(for: "消してくれる")

        XCTAssertTrue(candidates.contains("消す"))
    }

    // Verifies the lattice keeps the full benefactive span when the su-verb lemma is reachable.
    func testBuildLatticeUsesBenefactiveFormCandidateForSuVerb() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "消してくれる")

        let hasEdge = latticeEdges.contains { edge in
            edge.surface == "消してくれる"
        }
        XCTAssertTrue(hasEdge, "Lattice should contain an edge spanning 消してくれる")

        if hasEdge {
            let lemma = resources.segmenter.preferredLemma(for: "消してくれる")
            XCTAssertEqual(lemma, "消す", "preferredLemma for 消してくれる should be 消す, got \(lemma ?? "nil")")
        }
    }

    // Verifies ichidan te-forms recover their dictionary lemma so かなえて is not split into かなえ|て.
    func testDeinflectorRecoversIchidanLemmaFromTeFormForKanaete() throws {
        let candidates = try deinflectionCandidates(for: "かなえて")

        XCTAssertTrue(candidates.contains("かなえる"))
    }

    // Verifies the greedy walk selects かなえて as a single edge rather than splitting into かなえ|て.
    // Regression: the kanaExactBonus previously applied to multi-char kana stems, causing かなえ
    // (direct trie match) to tie with かなえて (deinflection match) and win via lemma scoring.
    func testGreedySelectionPrefersIchidanTeFormOverShorterStem() throws {
        let resources = try sharedResources()
        let result = resources.segmenter.longestMatchResult(for: "かなえて")

        let selectedSurfaces = result.selectedEdges.map { $0.surface }
        XCTAssertEqual(selectedSurfaces, ["かなえて"], "Expected [\"かなえて\"] but got \(selectedSurfaces)")
    }

    // Prints and verifies the real inclusion results for the katakana-heavy surface we have been inspecting.
    func testReportLatticeInclusionResultsForExaminedSurface() throws {
        let examinedText = "かなしみがいまセーラースマイル"
        let lines = try inclusionLines(for: examinedText)

        print("LATTICE INCLUSION REPORT \(examinedText)")
        for line in lines {
            print(line)
        }

        // Single katakana characters (ス, ル) are filtered by the standalone-kana gate and do not appear in the lattice.
        XCTAssertTrue(lines.contains { line in
            line.contains("スマイ [lemma: すまい]")
        })
        XCTAssertTrue(lines.contains { line in
            line.contains("イル [lemma: いる]")
        })
    }
}
