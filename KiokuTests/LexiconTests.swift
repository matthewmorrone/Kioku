import Foundation
import XCTest
@testable import Kioku

// Verifies UI-facing lexical surface methods against real dictionary and deinflection resources.
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

    // 触れられない is the negative potential/passive of ichidan 触れる (ふれる). The deinflector also
    // mechanically reaches godan 触る (さわる) at depth 2 via "られない→る" then "れる→る", because
    // the second rule treats any v1-state surface ending in れる as a godan-potential form. Before the
    // intermediate-shadowing gate the deeper 触る won the depth-descending sort, the sheet displayed
    // さわ ruby plus no alternatives (only one projected reading existed because deeper spurious paths
    // collapsed siblings). 触れる is itself a JMdict v1 entry, so the chain passing through it is the
    // spurious one — pin both the lemma and the reading to the shallower, linguistically-correct match.
    func testFurerarenaiResolvesToIchidanFurerNotSpuriousGodanSawaru() throws {
        let surface = try lexiconSurface()

        let lemmas = surface.lemma(surface: "触れられない")
        XCTAssertTrue(lemmas.contains("触れる"), "Expected 触れる in lemmas, got: \(lemmas)")
        XCTAssertFalse(lemmas.contains("触る"), "Did not expect spurious 触る in lemmas, got: \(lemmas)")

        let readings = surface.readings(surface: "触れられない")
        XCTAssertTrue(
            readings.contains(where: { $0.hasPrefix("ふれ") }),
            "Expected at least one ふれ-prefixed reading (from 触れる), got: \(readings)"
        )
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
    private static var cached: Lexicon?

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
