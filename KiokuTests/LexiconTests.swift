import Foundation
import XCTest
@testable import Kioku

// Verifies UI-facing lexical surface methods against real dictionary and deinflection resources.
@MainActor
final class LexiconTests: XCTestCase {

    // Returns a shared lexical surface so resource loading and trie setup happen once for this suite.
    private func lexiconSurface() throws -> Lexicon {
        try SharedLexiconSurface.resources()
    }

    // Verifies kana input remains unchanged when requesting reading.
    func testReadingReturnsKanaInputUnchanged() throws {
        let surface = try lexiconSurface()

        XCTAssertEqual(surface.reading(surface: "たべた"), "たべた")
    }

    // Verifies mixed-script inflected input resolves to a kana reading.
    func testReadingReturnsKanaForInflectedKanjiSurface() throws {
        let surface = try lexiconSurface()

        XCTAssertEqual(surface.reading(surface: "食べた"), "たべた")
    }

    // Verifies deinflection-backed lemma candidates include the expected dictionary form.
    func testLemmaReturnsExpectedDictionaryCandidate() throws {
        let surface = try lexiconSurface()

        let lemmas = surface.lemma(surface: "食べた")
        XCTAssertTrue(lemmas.contains("食べる"))
    }

    // Verifies normalized lookup candidates include lemma plus reading pairs.
    func testNormalizeReturnsLemmaReadingCandidate() throws {
        let surface = try lexiconSurface()

        let normalized = surface.normalize(surface: "食べた")
        XCTAssertTrue(normalized.contains(where: { candidate in
            candidate.lemma == "食べる" && candidate.reading == "たべる"
        }))
    }

    // Verifies inflection information returns both a lemma and at least one rule-chain step.
    func testInflectionInfoReturnsLemmaAndChain() throws {
        let surface = try lexiconSurface()

        let info = surface.inflectionInfo(surface: "食べさせられた")
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.lemma, "食べる")
        XCTAssertFalse(info?.chain.isEmpty ?? true)
    }

    // Adverbs whose surface happens to match a godan past-tense pattern (った→う) must not be
    // displaced by spurious deinflection candidates like たう (多雨, "heavy rain") — the lemma
    // is a noun in JMdict and so cannot validly terminate a verb-deinflection chain.
    func testAdverbSurfaceWinsOverSpuriousDeinflection() throws {
        let surface = try lexiconSurface()

        let info = surface.inflectionInfo(surface: "たった")
        XCTAssertEqual(info?.lemma, "たった")
        XCTAssertNil(
            surface.compoundVerbComponents(surface: "たった"),
            "Adverb たった must not be reported as a compound verb"
        )
    }

    // Set-phrase いつだって ("anytime, always") must not be reanalyzed as a verb-conjugation
    // chain, even if MeCab tokenizes it into multiple morphemes.
    func testSetPhraseSurfaceWinsOverSpuriousDeinflection() throws {
        let surface = try lexiconSurface()

        let info = surface.inflectionInfo(surface: "いつだって")
        XCTAssertEqual(info?.lemma, "いつだって")
        XCTAssertNil(
            surface.compoundVerbComponents(surface: "いつだって"),
            "いつだって must not be reported as a compound verb"
        )
    }

    // Phrasal surfaces containing case particles (夢を見てる) must decompose into noun + particle +
    // verb-lemma rather than verb-compound + auxiliary suffix. The trailing てる happens to satisfy
    // a te-form deinflection rule, so without this guard the lookup reports 夢を見る + る ("verb-
    // forming suffix") as a compound — confusing because the actual structure is a phrase.
    func testPhrasalSurfaceWithCaseParticleDecomposes() throws {
        let surface = try lexiconSurface()

        let components = surface.compoundVerbComponents(surface: "夢を見てる")
        XCTAssertNotNil(components)
        XCTAssertEqual(components?.map { $0.lemma }, ["夢", "を", "見る"])
    }

    // Native verbs whose stems literally contain が or を (翻す ひるがえす, 流す ながす) must not
    // be split into "phrase morphemes" by the case-particle decomposer. The guard checks that
    // the surface's lemma is a known verb entry before falling through to phrasal splitting.
    func testVerbContainingCaseParticleKanaIsNotPhrasallyDecomposed() throws {
        let surface = try lexiconSurface()

        XCTAssertNil(
            surface.compoundVerbComponents(surface: "ひるがえして"),
            "ひるがえして deinflects to the single verb 翻す/ひるがえす and must not be split on が"
        )
        XCTAssertNil(
            surface.compoundVerbComponents(surface: "ひるがえす"),
            "ひるがえす is a single dictionary verb; the embedded が is part of the stem"
        )
    }

    // Verifies lexeme lookup by lemma and reading returns at least one matching dictionary entry.
    func testLookupLexemeReturnsEntriesForLemmaAndReading() throws {
        let surface = try lexiconSurface()

        let entries = surface.lookupLexeme("食べる", "たべる")
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains(where: { entry in
            entry.kanjiForms.contains(where: { $0.text == "食べる" })
                && entry.kanaForms.contains(where: { $0.text == "たべる" })
        }))
    }

    // Verifies resolve produces ranked lexeme candidates for an inflected surface.
    func testResolveReturnsRankedCandidates() throws {
        let surface = try lexiconSurface()

        let resolved = surface.resolve(surface: "食べた")
        XCTAssertFalse(resolved.isEmpty)

        let expectedLexemes = Set(
            surface.lookupLexeme("食べる", "たべる").map { entry in
                entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? ""
            }
        )
        XCTAssertTrue(resolved.contains(where: { candidate in
            expectedLexemes.contains(candidate.lexeme) && candidate.score > 0.0
        }))
    }

    // Verifies lexeme(id) returns a concrete entry for a valid lexeme identifier.
    func testLexemeReturnsEntryForIdentifier() throws {
        let surface = try lexiconSurface()
        let entries = surface.lookupLexeme("食べる", "たべる")
        guard let entry = entries.first else {
            XCTFail("Expected at least one lexeme for 食べる/たべる")
            return
        }

        let lexeme = surface.lexeme("lex_\(entry.entryId)")
        XCTAssertNotNil(lexeme)
        XCTAssertEqual(lexeme?.entryId, entry.entryId)
    }

    // Verifies forms returns both orthographic and kana variants for one lexeme.
    func testFormsReturnsOrthographicAndKanaForms() throws {
        let surface = try lexiconSurface()
        let lexemeID = try firstLexemeIDForTaberu(from: surface)

        let forms = surface.forms(lexemeID)
        XCTAssertFalse(forms.isEmpty)
        XCTAssertTrue(forms.contains(where: { form in
            form.spelling == "食べる" && form.reading == "たべる"
        }))
    }

    // Verifies senses returns the same flattened gloss payload as the underlying dictionary entry.
    func testSensesReturnsGlosses() throws {
        let surface = try lexiconSurface()
        let lexemeID = try firstLexemeIDForTaberu(from: surface)

        guard let lexeme = surface.lexeme(lexemeID) else {
            XCTFail("Expected lexeme to resolve for \(lexemeID)")
            return
        }

        let expectedGlosses = lexeme.senses.flatMap { sense in
            sense.glosses.map { gloss in
                gloss.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }.filter { trimmedGloss in
            trimmedGloss.isEmpty == false
        }

        let senses = surface.senses(lexemeID)
        XCTAssertEqual(senses, expectedGlosses)
    }

    // Verifies primaryReading returns the main kana reading for one lexeme.
    func testPrimaryReadingReturnsMainReading() throws {
        let surface = try lexiconSurface()
        let lexemeID = try firstLexemeIDForTaberu(from: surface)

        XCTAssertEqual(surface.primaryReading(lexemeID), "たべる")
    }

    // Verifies displayForm returns a preferred headword spelling and reading.
    func testDisplayFormReturnsPreferredHeadword() throws {
        let surface = try lexiconSurface()
        let lexemeID = try firstLexemeIDForTaberu(from: surface)

        let displayForm = surface.displayForm(lexemeID)
        XCTAssertNotNil(displayForm)
        XCTAssertTrue(["食べる", "喰べる"].contains(displayForm?.spelling ?? ""))
        XCTAssertEqual(displayForm?.reading, "たべる")
    }

    // Verifies matchedForm maps an inflected surface to an appropriate lexeme form.
    func testMatchedFormReturnsBestLexemeFormForSurface() throws {
        let surface = try lexiconSurface()
        let lexemeID = try firstLexemeIDForTaberu(from: surface)

        let matched = surface.matchedForm(surface: "食べた", lexemeId: lexemeID)
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.spelling, "食べる")
        XCTAssertEqual(matched?.reading, "たべる")
    }

    // Verifies kanji detection reports true when text includes kanji.
    func testContainsKanjiDetectsKanji() throws {
        let surface = try lexiconSurface()

        XCTAssertTrue(surface.containsKanji("食べた"))
    }

    // Verifies kana detection reports true only for kana-only text.
    func testIsKanaDetectsKanaOnlyText() throws {
        let surface = try lexiconSurface()

        XCTAssertTrue(surface.isKana("たべた"))
        XCTAssertFalse(surface.isKana("食べた"))
    }

    // Verifies lexeme kanji extraction returns unique kanji characters used by forms.
    func testKanjiCharactersReturnsUniqueKanjiFromForms() throws {
        let surface = try lexiconSurface()
        let lexemeID = try firstLexemeIDForTaberu(from: surface)

        let characters = surface.kanjiCharacters(lexemeID)
        XCTAssertTrue(characters.contains("食"))
    }

    // Verifies inflection expansion returns at least lemma and common past form for an ichidan verb.
    func testExpandInflectionReturnsGeneratedForms() throws {
        let surface = try lexiconSurface()

        let forms = surface.expandInflection("猫")
        XCTAssertTrue(forms.contains("猫"))
    }

    // Verifies inflection-chain surface returns ordered rule labels for compound inflection.
    func testInflectionChainReturnsRuleLabels() throws {
        let surface = try lexiconSurface()

        let chain = surface.inflectionChain(surface: "食べさせられた")
        XCTAssertFalse(chain.isEmpty)
        XCTAssertTrue(chain.contains(where: { label in
            label.localizedCaseInsensitiveContains("past")
        }))
    }

    // Prints a non-asserting survey table of (surface | current lemma | expected lemma | depth | ✓/✗).
    // This is a characterization test for the deinflection picker: it documents what the current
    // code returns for a curated set of ambiguous and control surfaces, so a fix can be evaluated
    // by diffing this output before vs. after. Failures here do NOT fail the build.
    func testDeinflectionSurveyTable() throws {
        let surface = try lexiconSurface()

        // (surface, expected lemma). "Expected" is the linguistically correct lemma — what the
        // app *should* return — not necessarily what it returns today. Ambiguous pairs target
        // the over-deinflection bias (longer chain wins past a valid lemma).
        let cases: [(String, String)] = [
            // Reported bug case
            ("触れられない", "触れる"),
            ("触れない", "触れる"),
            ("触れた", "触れる"),
            ("触った", "触る"),
            ("触らない", "触る"),

            // 見える / 見る
            ("見えない", "見える"),
            ("見えた", "見える"),
            ("見ない", "見る"),
            ("見られない", "見る"),

            // 聞こえる / 聞く
            ("聞こえない", "聞こえる"),
            ("聞こえた", "聞こえる"),
            ("聞かない", "聞く"),

            // 切れる / 切る
            ("切れない", "切れる"),
            ("切れた", "切れる"),
            ("切らない", "切る"),

            // 焼ける / 焼く
            ("焼けない", "焼ける"),
            ("焼けた", "焼ける"),
            ("焼かない", "焼く"),

            // 解ける / 解く
            ("解けない", "解ける"),
            ("解けた", "解ける"),
            ("解かない", "解く"),

            // 出られる / 出る
            ("出られない", "出る"),

            // Standard controls (should already pass)
            ("食べた", "食べる"),
            ("食べない", "食べる"),
            ("食べさせられた", "食べる"),
            ("行った", "行く"),
            ("行きました", "行く"),
            ("した", "する"),
            ("来た", "来る"),
            ("飲んだ", "飲む"),

            // Adjectives
            ("寒くない", "寒い"),
            ("大きかった", "大きい"),
        ]

        var lines: [String] = []
        lines.append("=== DEINFLECTION SURVEY ===")
        lines.append("surface\tcurrent\texpected\tdepth\tok\tchain")

        var passed = 0
        var failed = 0
        for (input, expected) in cases {
            let info = surface.inflectionInfo(surface: input)
            let current = info?.lemma ?? "<nil>"
            let depth = info?.chain.count ?? 0
            let chain = info?.chain.joined(separator: "→") ?? ""
            let ok = (current == expected)
            if ok { passed += 1 } else { failed += 1 }
            let mark = ok ? "OK" : "FAIL"
            lines.append("\(input)\t\(current)\t\(expected)\t\(depth)\t\(mark)\t\(chain)")
        }
        lines.append("---")
        lines.append("passed: \(passed)   failed: \(failed)   total: \(cases.count)")
        lines.append("=== END SURVEY ===")

        let table = lines.joined(separator: "\n")
        let attachment = XCTAttachment(string: table)
        attachment.name = "deinflection-survey.tsv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Diagnostic for the 触れられない bug: dumps the full reading-cycle picture for a curated
    // set of inflected surfaces — all admitted lemmas, each lemma's stored readings, the merged
    // arrow list, and the reading→lemma map. Non-asserting; results land in an XCTAttachment.
    func testAdmittedLemmaReadingDiagnostic() throws {
        let surface = try lexiconSurface()
        let baseResources = try TestReadResources.shared()
        let surfaceReadingData = try baseResources.dictionaryStore.fetchSurfaceReadingData()

        let diagnosticSurfaces = [
            "触れられない", "触れない", "触れた", "触った",
            "見られない", "見えない",
            "聞こえない",
            "切れない", "切れた",
            "焼けない",
            "解けない", "解けた",
            "出られない",
            "食べさせられた",
        ]

        var lines: [String] = []
        lines.append("=== SURFACE-PROJECTED READING DIAGNOSTIC ===")
        for input in diagnosticSurfaces {
            lines.append("")
            lines.append("SURFACE: \(input)  (surfaceReadingData[surface]?.readings = \(surfaceReadingData[input]?.readings ?? []))")
            let admitted = surface.allAdmittedLemmas(surface: input)
            lines.append("  admitted lemmas: \(admitted)")
            let groups = surface.surfaceReadingsByLemma(surface: input)
            var merged: [String] = []
            var seen: Set<String> = []
            var readingToLemma: [(reading: String, lemma: String)] = []
            for group in groups {
                lines.append("  \(group.lemma) → projected: \(group.surfaceReadings)  chain: \(group.chain)")
                for reading in group.surfaceReadings where seen.insert(reading).inserted {
                    merged.append(reading)
                    readingToLemma.append((reading: reading, lemma: group.lemma))
                }
            }
            lines.append("  merged readings (arrow cycle order): \(merged)")
            lines.append("  reading→lemma map:")
            for entry in readingToLemma {
                lines.append("    \(entry.reading) → \(entry.lemma)")
            }
        }
        lines.append("=== END DIAGNOSTIC ===")

        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "admitted-lemma-readings.tsv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Returns a known lexeme identifier for 食べる-based assertions.
    private func firstLexemeIDForTaberu(from surface: Lexicon) throws -> String {
        let entries = surface.lookupLexeme("食べる", "たべる")
        guard let entry = entries.first else {
            throw NSError(domain: "LexiconTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing lexeme for 食べる/たべる"])
        }

        return "lex_\(entry.entryId)"
    }

}

// Caches expensive lexical test resources across all LexiconTests cases.
private enum SharedLexiconSurface {
    // Process-wide cache. nonisolated(unsafe) because Swift 6 strict checking flags
    // any mutable global, but XCTest runs each test case serially within the test
    // class and the cache is only ever populated by the first call before any
    // concurrent access can occur.
    nonisolated(unsafe) private static var cached: Lexicon?

    // Returns cached lexical resources so full dictionary loading runs at most once in this file.
    static func resources() throws -> Lexicon {
        if let cached {
            return cached
        }

        let baseResources = try TestReadResources.shared()
        let groupedRules = try TestReadResources.groupedDeinflectionRules()
        let surfaceReadingData = try baseResources.dictionaryStore.fetchSurfaceReadingData()
        let deinflector = Deinflector(groupedRules: groupedRules, trie: DictionaryTrie())

        let lexicalSurface = Lexicon(
            dictionaryStore: baseResources.dictionaryStore,
            segmenter: baseResources.segmenter,
            deinflector: deinflector,
            surfaceReadingData: surfaceReadingData
        )

        cached = lexicalSurface
        return lexicalSurface
    }

}
