import XCTest
@testable import Kioku

// Characterizes MatchingRoundBuilder: boards of at most five same-direction pairs, every word dealt
// at most once, no board with two tiles of identical text, and kana-only words kept off kanji
// boards.
@MainActor
final class MatchingRoundBuilderTests: XCTestCase {

    // Builds a study item with distinct kanji / kana / meaning text derived from `id`.
    private func item(_ id: Int64, kanji: String? = nil, kana: String? = nil, meaning: String? = nil) -> StudyItem {
        let hasKanji = kanji != nil
        return StudyItem(
            word: SavedWord(canonicalEntryID: id, surface: kanji ?? kana ?? "w\(id)"),
            surface: kanji ?? kana ?? "w\(id)",
            kanji: kanji,
            kana: kana ?? "かな\(id)",
            english: meaning ?? "meaning \(id)",
            glosses: [meaning ?? "meaning \(id)"],
            hasKanjiForm: hasKanji,
            wordClass: .noun
        )
    }

    // Deals with a fixed seed so failures reproduce.
    private func build(_ items: [StudyItem], _ selection: DirectionSelection = .all, seed: UInt64 = 1) -> [MatchingRound] {
        var generator = SeededGenerator(seed: seed)
        return MatchingRoundBuilder.build(from: items, selection: selection, using: &generator)
    }

    // Twelve dealable words become boards of five, five and two, each word exactly once.
    func testDealsEveryWordOnceInBoardsOfAtMostFive() {
        let items = (1...12).map { item(Int64($0), kanji: "漢\($0)") }
        let rounds = build(items)

        let dealt = rounds.flatMap { $0.pairs.map(\.id) }
        XCTAssertEqual(dealt.count, 12)
        XCTAssertEqual(Set(dealt), Set(1...12))
        XCTAssertTrue(rounds.allSatisfy { $0.pairs.count <= MatchingRoundBuilder.pairsPerRound })
        XCTAssertEqual(rounds.map(\.pairs.count), [5, 5, 2])
    }

    // The right column holds the same words as the left, and each pair carries the board's
    // direction's text on each side.
    func testAnswerOrderIsAPermutationAndTextFollowsDirection() {
        let items = (1...10).map { item(Int64($0), kanji: "漢\($0)") }
        for round in build(items) {
            XCTAssertEqual(Set(round.answerOrder), Set(round.pairs.map(\.id)))
            XCTAssertEqual(round.answerOrder.count, round.pairs.count)
            let fields = round.direction.fields
            for pair in round.pairs {
                let source = items.first { $0.id == pair.id }!
                XCTAssertEqual(pair.prompt, source.value(for: fields.prompt))
                XCTAssertEqual(pair.answer, source.value(for: fields.answer))
            }
        }
    }

    // Two words sharing a meaning never land on the same kanji→English board, since either
    // pairing would be correct.
    func testWordsWithTheSameAnswerNeverShareABoard() {
        let items = [
            item(1, kanji: "闇", meaning: "darkness"),
            item(2, kanji: "暗闇", meaning: "darkness"),
            item(3, kanji: "光", meaning: "light"),
            item(4, kanji: "水", meaning: "water"),
            item(5, kanji: "火", meaning: "fire"),
        ]
        let rounds = build(items, DirectionSelection(directions: [.kanjiToMeaning]))
        for round in rounds {
            XCTAssertEqual(Set(round.pairs.map(\.answer)).count, round.pairs.count)
            XCTAssertEqual(Set(round.pairs.map(\.prompt)).count, round.pairs.count)
        }
        XCTAssertEqual(Set(rounds.flatMap { $0.pairs.map(\.id) }), Set(1...5))
    }

    // A kana-only word can't be asked a kanji direction, so with only kanji directions ticked it is
    // left out; on a mixed selection it lands only on boards it can be asked.
    func testKanaOnlyWordsStayOffKanjiBoards() {
        let kanjiWords = (1...5).map { item(Int64($0), kanji: "漢\($0)") }
        let kanaWords = (6...8).map { item(Int64($0)) }

        let kanjiOnly = build(kanjiWords + kanaWords, DirectionSelection(directions: [.kanjiToMeaning]))
        XCTAssertEqual(Set(kanjiOnly.flatMap { $0.pairs.map(\.id) }), Set(1...5))

        for seed in UInt64(1)...20 {
            for round in build(kanjiWords + kanaWords, seed: seed) where round.direction.requiresKanji {
                XCTAssertTrue(round.pairs.allSatisfy(\.hasKanjiForm))
            }
        }
    }

    // Six words deal as 4 + 2, not 5 + a lone word that would have to be dropped.
    func testFullBoardLeavesNoLoneWord() {
        let items = (1...6).map { item(Int64($0), kanji: "漢\($0)") }
        let rounds = build(items, DirectionSelection(directions: [.kanjiToMeaning]))
        XCTAssertEqual(rounds.map(\.pairs.count), [4, 2])
        XCTAssertEqual(Set(rounds.flatMap { $0.pairs.map(\.id) }), Set(1...6))
    }

    // A word nothing can share a board with (here: the only other word has the same answer) is
    // dropped rather than shown as a one-tile board.
    func testUnpairableWordIsDroppedNotShownAlone() {
        let items = [item(1, kanji: "闇", meaning: "darkness"), item(2, kanji: "暗闇", meaning: "darkness")]
        let rounds = build(items, DirectionSelection(directions: [.kanjiToMeaning]))
        XCTAssertTrue(rounds.isEmpty)
    }

    // Every pair on a board uses the board's own direction, which must be one of the ticked ones.
    func testBoardsOnlyUseSelectedDirections() {
        let items = (1...20).map { item(Int64($0), kanji: "漢\($0)") }
        let selection = DirectionSelection(directions: [.kanaToMeaning, .meaningToKanji])
        for seed in UInt64(1)...10 {
            for round in build(items, selection, seed: seed) {
                XCTAssertTrue(selection.directions.contains(round.direction))
            }
        }
    }
}
