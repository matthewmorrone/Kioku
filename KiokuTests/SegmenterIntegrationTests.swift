import XCTest
@testable import Kioku

// Exercises the real segmenter pipeline against a few small strings without rebuilding the trie per test.
@MainActor
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

    // Verifies adjective appearance ("-げ") forms recover their base adjective lemma so the
    // surface gets correct readings and lookup. 眩しげ is the appearance form of 眩しい; without
    // this rule it resolved to no lemma at all (bare kanji, empty lookup sheet).
    func testDeinflectorRecoversAdjectiveLemmaFromGeAppearanceForm() throws {
        let candidates = try deinflectionCandidates(for: "眩しげ")

        XCTAssertTrue(candidates.contains("眩しい"))
    }

    // Verifies godan causative te-forms recover their dictionary-form lemma.
    func testDeinflectorRecoversGodanLemmaFromCausativeTeForm() throws {
        let candidates = try deinflectionCandidates(for: "覗かせて")

        XCTAssertTrue(candidates.contains("覗く"))
    }

    // Verifies the contracted progressive (〜てる = 〜ている with い dropped) recovers the
    // dictionary form for godan く verbs. 輝いてる is 輝く's progressive; without the いてる→く
    // rule the segmenter could only strip the te-form (輝いて) and orphaned the contracted る,
    // splitting 輝いてる into 輝いて | る. Its voiced sibling いでる→ぐ and full form いている→く
    // already existed; this was a hole in the contracted-progressive set.
    func testDeinflectorRecoversGodanKuLemmaFromContractedProgressive() throws {
        let candidates = try deinflectionCandidates(for: "輝いてる")

        XCTAssertTrue(candidates.contains("輝く"))
    }

    // Verifies the contracted progressive recovers ぬ-verb lemmas (死んでる → 死ぬ). The
    // contracted んでる set had む/ぶ but was missing ぬ, the third んでいる ending.
    func testDeinflectorRecoversNuLemmaFromContractedProgressive() throws {
        let candidates = try deinflectionCandidates(for: "死んでる")

        XCTAssertTrue(candidates.contains("死ぬ"))
    }

    // Verifies additional adjective nominalized forms recover their base adjective lemma.
    func testDeinflectorRecoversAdjectiveLemmaFromSaNominalizationForAishisa() throws {
        let candidates = try deinflectionCandidates(for: "愛しさ")

        XCTAssertTrue(candidates.contains("愛しい"))
    }

    // した is the standalone past tense of the irregular する, but する conjugates
    // as a whole word (kanaIn した == the entire surface, so the stem is empty).
    // The deinflector's empty-stem guard used to reject every whole-surface
    // match, so した never recovered する — only the spurious ichidan reading しる
    // (た→る) survived. Whole irregular forms whose result is a real dictionary
    // word must be admitted.
    func testDeinflectorRecoversSuruFromStandaloneShita() throws {
        let candidates = try deinflectionCandidates(for: "した")

        XCTAssertTrue(candidates.contains("する"),
                      "standalone した must deinflect to する — got \(candidates.sorted())")
    }

    // きた is the standalone past of くる (same whole-word irregular shape). Same
    // empty-stem guard, same fix.
    func testDeinflectorRecoversKuruFromStandaloneKita() throws {
        let candidates = try deinflectionCandidates(for: "きた")

        XCTAssertTrue(candidates.contains("くる"),
                      "standalone きた must deinflect to くる — got \(candidates.sorted())")
    }

    // End-to-end: with POS data wired into the segmenter, the lemma-candidate gate keeps the
    // deinflected verb する (a verb) for した instead of dropping it, so the "Choose Lemma…"
    // picker offers both the noun reading した (→ 下 / 舌 at lookup) and the verb する.
    func testLemmaCandidatesOfferSuruForShita() throws {
        let segmenter = try sharedResources().segmenter
        let candidates = segmenter.lemmaCandidates(for: "した")

        XCTAssertTrue(candidates.contains("する"),
                      "picker must offer する for した — got \(candidates)")
        XCTAssertTrue(candidates.contains("した"),
                      "picker must still offer the noun reading した — got \(candidates)")
    }

    // The empty-stem admission must not turn bare grammatical endings into words:
    // a single-kana stem-recovery rule (し ⇒ する) needs a real preceding stem,
    // so a bare し must not deinflect to する.
    func testDeinflectorDoesNotRecoverSuruFromBareShi() throws {
        let candidates = try deinflectionCandidates(for: "し")

        XCTAssertFalse(candidates.contains("する"),
                       "bare し should not spawn する without a stem — got \(candidates.sorted())")
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

    // MARK: - Structural invariants (docs/INVARIANTS.md "Segmentation" #1, #2)
    //
    // The lattice is intentionally overlapping (it carries alternatives), but the
    // *chosen* path (`longestMatchEdges`) must tile the source text exactly:
    //   #1 Total coverage — every UTF-16 unit belongs to some chosen edge.
    //   #2 Disjoint — no two chosen edges overlap.
    //
    // Violating either causes hard-to-diagnose downstream bugs: gaps in coverage
    // produce un-styled glyphs in the renderer and skip tap handling; overlaps
    // cause double-tap, double-coloring, and divergent furigana resolution
    // between the two overlapping edges.

    func testLongestMatchEdgesTileSourceWithoutGapsOrOverlap() throws {
        // Mix of lyric snippets that touched today's segmentation bugs plus a
        // pure-kana and pure-katakana case. Run the invariant on each.
        let corpus = [
            "朽ちた花びらに黄昏の翅が",
            "もう触れられないあの日の命を",
            "悲しみの嘘を忘れない",
            "夕映の時間はもう無いけれど",
            "には",
            "プレイヤーズ",
            "abc"
        ]
        let resources = try sharedResources()
        for text in corpus {
            let edges = resources.segmenter.longestMatchEdges(for: text)
            assertEdgesTileText(edges, text: text)
        }
    }

    // Walks `edges` in source-position order and verifies that the first edge
    // starts at text.startIndex, each subsequent edge starts exactly where the
    // previous one ended, and the last edge ends at text.endIndex. Any gap
    // (covering #1) or overlap (covering #2) fails the assertion with a
    // descriptive message.
    private func assertEdgesTileText(
        _ edges: [LatticeEdge],
        text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sorted = edges.sorted { lhs, rhs in
            text.distance(from: text.startIndex, to: lhs.start)
                < text.distance(from: text.startIndex, to: rhs.start)
        }
        var cursor = text.startIndex
        for edge in sorted {
            XCTAssertEqual(
                edge.start, cursor,
                "Edge \(edge.surface) starts at \(text.distance(from: text.startIndex, to: edge.start)) but previous edge ended at \(text.distance(from: text.startIndex, to: cursor)) — coverage gap or overlap",
                file: file, line: line
            )
            cursor = edge.end
        }
        XCTAssertEqual(
            cursor, text.endIndex,
            "Edges stop at \(text.distance(from: text.startIndex, to: cursor)) but text length is \(text.distance(from: text.startIndex, to: text.endIndex)) — missing tail coverage",
            file: file, line: line
        )
    }
}
