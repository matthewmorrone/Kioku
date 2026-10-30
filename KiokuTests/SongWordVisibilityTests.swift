import XCTest
@testable import Kioku

// Verifies the Breakdown's show/hide options (SongWordVisibility): each kind of word is hidden
// only by its own option, English bullets are always hidden, and vocalization lines (and
// repeats pointing at one) drop out while vocalizations are hidden.
final class SongWordVisibilityTests: XCTestCase {
    private let showAll = SongWordVisibility(showsParticles: true, showsKatakana: true, showsVocalizations: true, showsPatterns: true)
    private let hideAll = SongWordVisibility(showsParticles: false, showsKatakana: false, showsVocalizations: false, showsPatterns: false)

    // Builds a bare line for visibility checks.
    private func line(_ index: Int, vocalization: Bool = false, reference: LineReference? = nil) -> SongLine {
        SongLine(index: index, original: "ラララ", romaji: nil, words: [], gist: nil, grammarNote: nil,
                 reference: reference, isVocalization: vocalization ? true : nil)
    }

    // Each kind is shown when its option is on and hidden when off; plain vocabulary always shows.
    func testWordKindsFollowTheirOptions() {
        let particle = SongWord(surface: "を", sungRomaji: "wo", definition: "object marker")
        let taggedParticle = SongWord(surface: "よね", sungRomaji: "yone", definition: "seeking agreement", grammarTag: "particle")
        let katakana = SongWord(surface: "パレード", sungRomaji: "pareedo", definition: "parade")
        let vocal = SongWord(surface: "ああ", sungRomaji: "aa", definition: "sigh", grammarTag: "vocalization")
        let noun = SongWord(surface: "夕凪", sungRomaji: "yuunagi", definition: "evening calm")
        for word in [particle, taggedParticle, katakana, vocal, noun] {
            XCTAssertTrue(showAll.shows(word), word.surface)
        }
        XCTAssertFalse(hideAll.shows(particle))
        XCTAssertFalse(hideAll.shows(taggedParticle))
        XCTAssertFalse(hideAll.shows(katakana))
        XCTAssertFalse(hideAll.shows(vocal))
        XCTAssertTrue(hideAll.shows(noun))
    }

    // Words on KanaData.nonParticleWords (まで, ほど) stay visible even when a breakdown tags them [particle].
    func testListedNonParticlesStayVisible() {
        for surface in ["まで", "ほど"] {
            let word = SongWord(surface: surface, sungRomaji: "", definition: "until / extent", grammarTag: "particle")
            XCTAssertTrue(hideAll.shows(word), surface)
        }
    }

    // An English surface is never shown, whatever the options.
    func testEnglishBulletAlwaysHidden() {
        XCTAssertFalse(showAll.shows(SongWord(surface: "baby", sungRomaji: "", definition: "baby")))
    }

    // A vocalization line, and a "= line N" repeat of one, hide with vocalizations off.
    func testVocalizationLinesHideWithTheirRepeats() {
        let vocalLine = line(1, vocalization: true)
        let repeatLine = line(2, reference: .sameAsLine(1))
        let byIndex = [1: vocalLine, 2: repeatLine]
        XCTAssertFalse(hideAll.showsLine(vocalLine, linesByIndex: byIndex))
        XCTAssertFalse(hideAll.showsLine(repeatLine, linesByIndex: byIndex))
        XCTAssertTrue(showAll.showsLine(vocalLine, linesByIndex: byIndex))
        XCTAssertTrue(hideAll.showsLine(line(3), linesByIndex: byIndex))
    }
}
