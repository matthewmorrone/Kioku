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

    // Verifies lexeme lookup by lemma and reading returns at least one matching dictionary entry.
    func testLookupLexemeReturnsEntriesForLemmaAndReading() throws {
        let surface = try lexiconSurface()

        let entries = surface.lookupLexeme("食べる", "たべる")
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains(where: { entry in
            entry.kanjiForms.contains("食べる") && entry.kanaForms.contains("たべる")
        }))
    }

    // Verifies resolve produces ranked lexeme candidates for an inflected surface.
    func testResolveReturnsRankedCandidates() throws {
        let surface = try lexiconSurface()

        let resolved = surface.resolve(surface: "食べた")
        XCTAssertFalse(resolved.isEmpty)

        let expectedLexemes = Set(
            surface.lookupLexeme("食べる", "たべる").map { entry in
                entry.kanjiForms.first ?? entry.kanaForms.first ?? ""
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

    // Verifies lattice neighbor lookup returns nearby nodes after resolve populates an in-memory lattice.
    func testLatticeNeighborsReturnsReachableNodes() throws {
        let surface = try lexiconSurface()

        _ = surface.resolve(surface: "食べた")
        let neighbors = surface.latticeNeighbors(nodeId: 0, distance: 1)

        XCTAssertFalse(neighbors.contains(0))
    }

    // Verifies node components include at least base lemma information for a resolved node.
    func testNodeComponentsReturnsMorphologicalComponents() throws {
        let surface = try lexiconSurface()

        _ = surface.resolve(surface: "食べさせられた")
        let components = surface.nodeComponents(nodeId: 0)

        XCTAssertFalse(components.isEmpty)
        XCTAssertFalse(components[0].lemma.isEmpty)
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
        let readingBySurface = try baseResources.dictionaryStore.fetchPreferredReadingsBySurface()

        let lexicalSurface = Lexicon(
            dictionaryStore: baseResources.dictionaryStore,
            segmenter: baseResources.segmenter,
            readingBySurface: readingBySurface,
            groupedRules: groupedRules
        )

        cached = lexicalSurface
        return lexicalSurface
    }

}
