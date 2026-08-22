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

    // Reproduces ReadView.definitionPayloadForSelectedSegment's exact resolution path for the
    // reported "popover sometimes doesn't appear" bug (さがしつづける), run repeatedly to catch
    // intermittent/order-dependent failures a single call wouldn't surface. Live device console
    // capture kept losing the reproduction window to app-relaunch navigation resets, so this
    // exercises the identical dictionary-backed pipeline entirely on the host, no device needed.
    func testCompoundVerbDefinitionLookupIsReliableAcrossRepeatedCalls() throws {
        let resources = try sharedResources()
        let surface = "さがしつづける"

        for iteration in 0..<50 {
            let lemma = resources.segmenter.preferredLemma(for: surface)
            XCTAssertEqual(lemma, "さがす", "preferredLemma flaked on iteration \(iteration)")

            guard let lemma else { continue }
            let entries = try resources.dictionaryStore.lookup(surface: lemma, mode: .kanaOnly)
            XCTAssertFalse(entries.isEmpty, "dictionary lookup for \(lemma) returned no entries on iteration \(iteration)")

            let hasUsableGloss = entries.contains { entry in
                entry.senses.contains { sense in
                    sense.glosses.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                }
            }
            XCTAssertTrue(hasUsableGloss, "no usable gloss found for \(lemma) on iteration \(iteration)")
        }
    }

    // しちゃう (contraction of して + しまう, i.e. する + auxiliary しまう) must lemmatize to
    // する. A user report showed it resolving to しる ("to know") instead — a real dictionary
    // word, just linguistically impossible here: 知る is godan despite ending in る, so its
    // real contraction is 知っちゃう/しっちゃう (small っ), never しちゃう. The generic v1
    // "ちゃう→る" rule doesn't verify the candidate is actually ichidan, so it admitted しる as
    // a false positive that out-ranked the correct explicit "しちゃう→する" rule. Fixed via
    // Deinflector.knownNonIchidanRuVerbs rejecting known godan-る-verb false positives.
    func testShichauLemmatizesToSuru() throws {
        let resources = try sharedResources()
        XCTAssertEqual(resources.segmenter.preferredLemma(for: "しちゃう"), "する")

        let candidates = resources.segmenter.lemmaCandidates(for: "しちゃう")
        XCTAssertFalse(candidates.contains("しる"), "しる should never be an admitted candidate for しちゃう")
    }

    // Reproduces the auxiliaryVerbSplit fallback path added to definitionPayloadForSelectedSegment,
    // confirming it independently recovers さがす even without relying on preferredLemma's single
    // compoundVerbRecoveryForms rule matching the whole 7-character surface.
    func testAuxiliaryVerbSplitFallbackRecoversCompoundVerbBase() throws {
        let resources = try sharedResources()
        let latticeEdges = try resources.segmenter.buildLattice(for: "さがしつづける")

        guard let split = LatticeEdge.auxiliaryVerbSplit(from: latticeEdges, auxiliaries: DerivationAnalyzer.auxiliaryVerbs) else {
            XCTFail("auxiliaryVerbSplit found no split for さがしつづける")
            return
        }

        let resolvedBase = resources.segmenter.preferredLemma(for: split[0]) ?? split[0]
        XCTAssertEqual(resolvedBase, "さがす")

        let entries = try resources.dictionaryStore.lookup(surface: resolvedBase, mode: .kanaOnly)
        XCTAssertFalse(entries.isEmpty)
    }

    // preferredLemma("ゆこう") resolves to "ゆこう" itself, not "ゆく" — the surface coincidentally
    // has its own unrelated real dictionary entry, and preferredLemma's surface-equality preference
    // ranks that self-match first (same failure shape as the どこかに/Turkey bug in
    // testShichauLemmatizesToSuru's neighborhood). preferredLemma(for:preferring:) must look past
    // that and find "ゆく" among the other candidates.
    func testPreferredLemmaPreferringAuxiliaryFindsYukuOverSelfMatch() throws {
        let resources = try sharedResources()
        XCTAssertEqual(resources.segmenter.preferredLemma(for: "ゆこう"), "ゆこう")
        XCTAssertEqual(
            resources.segmenter.preferredLemma(for: "ゆこう", preferring: DerivationAnalyzer.auxiliaryVerbs),
            "ゆく"
        )
    }

    // 歩いてゆこう (歩く + てゆこう, the volitional of auxiliary ゆく) must recover as a compound verb
    // end to end: auxiliaryVerbSplit finds the correct headEdge/tailEdge boundary, preferredLemma
    // resolves both parts to real dictionary lemmas, and DerivationAnalyzer names the compound.
    // Two coincidental false positives had to be fixed for this to work: (1) preferredLemma("ゆこう")
    // preferring its own unrelated dictionary entry over the deinflected "ゆく", and (2)
    // auxiliaryVerbSplit matching a shorter tail ("いてゆこう" → the real but wrong auxiliary いる)
    // before ever considering the linguistically correct て-linked split.
    func testAuxiliaryVerbSplitRecoversWalkingCompoundAcrossVolitionalTail() throws {
        let resources = try sharedResources()
        let surface = "歩いてゆこう"
        let edges = try buildLattice(for: surface)

        guard let split = LatticeEdge.auxiliaryVerbSplit(
            from: edges,
            auxiliaries: DerivationAnalyzer.auxiliaryVerbs,
            lemmaResolver: { resources.segmenter.preferredLemma(for: $0, preferring: DerivationAnalyzer.auxiliaryVerbs) }
        ) else {
            XCTFail("auxiliaryVerbSplit found no split for 歩いてゆこう")
            return
        }
        XCTAssertEqual(split, ["歩いて", "ゆこう"])

        let resolvedSplit = split.map { resources.segmenter.preferredLemma(for: $0, preferring: DerivationAnalyzer.auxiliaryVerbs) ?? $0 }
        XCTAssertEqual(resolvedSplit, ["歩く", "ゆく"])

        let derived = DerivationAnalyzer.analyze(
            surface: surface, components: resolvedSplit,
            baseResolver: { lemma in
                let entries = (try? resources.dictionaryStore.lookup(surface: lemma, mode: .kanjiAndKana)) ?? []
                return entries.flatMap { $0.senses.compactMap(\.pos) }.flatMap { $0.components(separatedBy: ",") }
            },
            glossResolver: { lemma in
                let entries = (try? resources.dictionaryStore.lookup(surface: lemma, mode: .kanjiAndKana)) ?? []
                return entries.first?.senses.first?.glosses.first
            }
        )
        XCTAssertEqual(derived?.compoundVerbParts?.base, "歩く")
        XCTAssertEqual(derived?.compoundVerbParts?.auxiliary, "ゆく")
        XCTAssertEqual(derived?.compoundVerbParts?.baseGloss, "to walk")
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
        let candidates = resources.segmenter.lemmaCandidates(for: "できない")
        let inclusion = try inclusionLines(for: "できない").joined(separator: "\n")

        XCTAssertTrue(latticeEdges.contains { edge in
            edge.surface == "できない" && resources.segmenter.preferredLemma(for: edge.surface) == "できる"
        }, "Expected できない → できる; candidates=\(candidates)\nlattice:\n\(inclusion)")
    }

    // docs/INVARIANTS.md "Segmentation" #5 (lemma resolution) — pins the
    // frequency-tiebreak contract after frequency was demoted from a weighted
    // term in `preferredLemmaScore` to a pure post-structural tiebreak.
    //
    // The past-tense なった deinflects to two pure-kana, length-2 verb lemmas,
    // {なう, なる}, that the structural signals (surface-equality, script,
    // prefix) cannot separate — their `preferredLemmaScore` is identical. Only
    // the corpus frequency breaks the tie, and it must favor the common なる
    // over the rare なう. Were frequency ever dropped from the comparison (or
    // ordered after the lexicographic fallback), なう would win and furigana
    // would resolve to the wrong reading.
    func testPreferredLemmaUsesFrequencyTiebreakForNattaCollision() throws {
        let resources = try sharedResources()
        let candidates = resources.segmenter.lemmaCandidates(for: "なった")

        XCTAssertTrue(
            candidates.contains("なる") && candidates.contains("なう"),
            "Expected both tie candidates present; candidates=\(candidates)"
        )
        XCTAssertEqual(
            resources.segmenter.preferredLemma(for: "なった"), "なる",
            "Frequency tiebreak must pick the common なる over the rare なう; candidates=\(candidates)"
        )
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

    // Characterization: records exactly which segmentation paths validPaths enumerates for どこかに,
    // the reported "only doko+kani, missing dokoka+ni" case. Prints the full edge set and paths so
    // we can see whether the gap is in the lattice/validPaths (data) or in a UI layer above it.
    func testValidPathsForDokokani() throws {
        let text = "どこかに"
        let resources = try sharedResources()
        let edges = resources.segmenter.buildLattice(for: text)

        let edgeLines = edges
            .map { edge -> String in
                let s = text.distance(from: text.startIndex, to: edge.start)
                let e = text.distance(from: text.startIndex, to: edge.end)
                return "\(s)->\(e) \(edge.surface)"
            }
            .sorted()
        print("[dokokani] edges:\n  " + edgeLines.joined(separator: "\n  "))

        let paths = LatticeEdge.validPaths(from: edges)
        let pathLines = paths.map { $0.joined(separator: "·") }
        print("[dokokani] validPaths:\n  " + pathLines.joined(separator: "\n  "))

        XCTAssertTrue(
            edges.contains { $0.surface == "どこか" },
            "lattice is missing the どこか edge — root cause is the trie/buildLattice, not the UI"
        )
        XCTAssertTrue(
            paths.contains(["どこか", "に"]),
            "validPaths omits どこか·に even though the edge exists — root cause is validPaths/section filtering"
        )
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

    // A sokuon (っ/ッ) is phonologically bound and can never begin a word, so the selected
    // segmentation must never emit a lone small-tsu segment — a stranded tsu is absorbed into the
    // preceding segment. Casual/subtitle speech (好きっ, えっ, …) triggers this; pre-fix the greedy
    // walk left っ as its own fallback segment.
    func testStrandedSmallTsuNeverFormsOwnSegment() throws {
        let segmenter = try sharedResources().segmenter
        for text in ["好きっ", "えっ", "あっ。", "ありがとうっ", "だめっ"] {
            let surfaces = segmenter.longestMatchEdges(for: text).map(\.surface)
            XCTAssertFalse(
                surfaces.contains { $0 == "っ" || $0 == "ッ" },
                "Lone small-tsu segment in \"\(text)\": \(surfaces)"
            )
        }
    }

    // The absorb must NOT over-merge: a small-tsu that heads a multi-char run (って quotative, った …)
    // keeps its own segment rather than being swallowed backward. Guards the fix against regressing
    // legitimate っ-initial tokens.
    func testSmallTsuHeadingMultiCharRunIsPreserved() throws {
        let segmenter = try sharedResources().segmenter
        let surfaces = segmenter.longestMatchEdges(for: "言うって").map(\.surface)
        XCTAssertTrue(
            surfaces.contains("言う"),
            "Expected 言う to remain its own segment in \(surfaces)"
        )
    }

    // Reduplicated adverbs (もっともっと, ずっとずっと) tempt the greedy walk into taking the longer
    // dictionary word at the head (もっとも 尤も) and stranding a bare っ. The lone っ must never
    // survive as its own segment, and the head must stay もっと.
    func testReduplicatedAdverbDoesNotStrandSmallTsu() throws {
        let segmenter = try sharedResources().segmenter
        let surfaces = segmenter.longestMatchEdges(for: "もっともっと愛している").map(\.surface)
        XCTAssertFalse(
            surfaces.contains { $0 == "っ" || $0 == "ッ" },
            "Lone small-tsu segment in もっともっと愛している: \(surfaces)"
        )
        XCTAssertEqual(surfaces.first, "もっと", "Expected もっと head, got \(surfaces)")
    }

    // Small kana (ゃゅょ, ぁぃぅぇぉ, …) and the prolonged sound mark are categorically never
    // word-initial, so the selected segmentation must never start a segment with one — they are
    // absorbed into the preceding segment, exactly like a stranded small-tsu.
    func testNeverInitialKanaNeverBeginsSegment() throws {
        let segmenter = try sharedResources().segmenter
        for text in ["きゃっ", "ふぁ", "しょ", "ぎゃー"] {
            let surfaces = segmenter.longestMatchEdges(for: text).map(\.surface)
            for surface in surfaces {
                let leadsWithBound = surface.first.map { Segmenter.neverInitialKana.contains($0) } ?? false
                XCTAssertFalse(
                    leadsWithBound,
                    "Segment begins with a never-initial kana in \"\(text)\": \(surfaces)"
                )
            }
        }
    }

    // InflectionFormNames used to be keyed by the raw deinflection.json group names ("teForms",
    // "progressiveForms"), but Deinflector.normalizedRuleLabel already strips "Forms" and splits
    // camelCase before a chain ever leaves the deinflector — so every describe(_:) lookup missed
    // silently and no word ever showed a grammatical-form caption. 見てる (見る's
    // casual progressive contraction) is a real example: its chain is ["progressive"], not
    // ["progressiveForms"].
    func testInflectionFormNamesMatchesRealDeinflectorChain() throws {
        let resources = try sharedResources()
        let lexicon = Lexicon(
            dictionaryStore: resources.dictionaryStore,
            segmenter: resources.segmenter,
            deinflector: resources.deinflector,
            surfaceReadingData: [:]
        )
        let info = try XCTUnwrap(lexicon.inflectionInfo(surface: "見てる"))
        XCTAssertEqual(info.lemma, "見る")
        XCTAssertEqual(info.chain, ["progressive"])
        XCTAssertEqual(InflectionFormNames.describe(info.chain), "progressive")
    }

    // キス is tagged "n,vs" in JMdict — a suru-noun with no written "キスする" headword (the vs tag
    // alone is meant to signal "attach する"). Regression for the buildLattice exception that
    // admits katakana-noun+conjugated-する spans across the hiragana/katakana boundary, and for
    // Lexicon.inflectionInfo routing the compound straight to キス's real dictionary entry instead
    // of failing to resolve a synthetic "キスする" surface that was never added to the dictionary.
    func testSuruCompoundVerbMergesKatakanaNounWithConjugatedSuru() throws {
        let resources = try sharedResources()

        let edges = resources.segmenter.longestMatchEdges(for: "キスして")
        XCTAssertEqual(edges.map(\.surface), ["キスして"])

        let lexicon = Lexicon(
            dictionaryStore: resources.dictionaryStore,
            segmenter: resources.segmenter,
            deinflector: resources.deinflector,
            surfaceReadingData: [:]
        )
        let info = try XCTUnwrap(lexicon.inflectionInfo(surface: "キスして"))
        XCTAssertEqual(info.lemma, "キス")

        let entries = try resources.dictionaryStore.lookup(surface: "キス", mode: .kanaOnly)
        XCTAssertFalse(entries.isEmpty)
    }

    // A plain (non-vs) katakana noun followed by unrelated hiragana must NOT merge — this is
    // exactly the bug class the hiragana/katakana guard exists to prevent (ビロード+の→「ドの」→
    // どの). ビロード carries no verb bit, so suruCompoundPrefix must reject it and buildLattice
    // must still split at the script boundary as before.
    func testSuruCompoundExceptionDoesNotAdmitPlainKatakanaNounPlusUnrelatedHiragana() throws {
        let resources = try sharedResources()
        XCTAssertNil(resources.segmenter.suruCompoundPrefix(for: "ビロードの"))
    }
}
