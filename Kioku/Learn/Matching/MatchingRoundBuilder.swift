import Foundation

// Deals a session's study items into Matching boards. Pure (items, direction selection and a
// random generator in; rounds out) so the dealing rules are unit-testable without stores or
// SwiftUI.
enum MatchingRoundBuilder {
    // Pairs per board — five down each side.
    static let pairsPerRound = 5
    // A one-pair board is solved before it's read, so a word that can't be given company in any
    // direction is left out of the session rather than shown alone.
    static let minimumPairsPerRound = 2

    // Deals `items` into boards. Each board takes the first remaining word as its lead, picks one of
    // the lead's askable directions at random, and fills up with other remaining words askable the
    // same way — so boards vary in direction while every column stays one kind of text. Two words
    // whose prompt or answer text coincide never share a board, since the board would then have two
    // right answers for one tile.
    static func build(
        from items: [StudyItem],
        selection: DirectionSelection,
        using generator: inout some RandomNumberGenerator
    ) -> [MatchingRound] {
        var remaining = items.shuffled(using: &generator)
        var rounds: [MatchingRound] = []

        while remaining.isEmpty == false {
            let lead = remaining[0]
            var dealt: (direction: QuestionDirection, pairs: [MatchingPair], indices: [Int])?
            // Try the lead's directions in random order until one gives it company; a direction
            // only its own kind of word can take (e.g. a kanji direction late in a kana-heavy pool)
            // shouldn't strand it when another direction would fill a board.
            for direction in askableDirections(for: lead, selection: selection).shuffled(using: &generator) {
                let attempt = deal(direction, from: remaining, selection: selection)
                if attempt.pairs.count >= minimumPairsPerRound {
                    dealt = (direction, attempt.pairs, attempt.indices)
                    break
                }
            }

            guard let dealt else {
                // Nothing to pair the lead with in any direction it can be asked.
                remaining.removeFirst()
                continue
            }
            for index in dealt.indices.reversed() {
                remaining.remove(at: index)
            }
            rounds.append(MatchingRound(
                id: rounds.count,
                direction: dealt.direction,
                pairs: dealt.pairs,
                answerOrder: dealt.pairs.map(\.id).shuffled(using: &generator)
            ))
        }
        return rounds
    }

    // Fills one board in `direction` from `remaining`, in order, skipping words that can't be asked
    // that way or would duplicate a tile already on the board. Returns the pairs and the indices
    // they were taken from. The first askable word (the lead) is always taken, since nothing is on
    // the board yet to collide with.
    private static func deal(
        _ direction: QuestionDirection,
        from remaining: [StudyItem],
        selection: DirectionSelection
    ) -> (pairs: [MatchingPair], indices: [Int]) {
        var pairs: [MatchingPair] = []
        var indices: [Int] = []
        var usedIDs: Set<Int64> = []
        var usedPrompts: Set<String> = []
        var usedAnswers: Set<String> = []
        let fields = direction.fields

        for (index, item) in remaining.enumerated() {
            guard pairs.count < pairsPerRound else { break }
            guard askableDirections(for: item, selection: selection).contains(direction) else { continue }
            let prompt = item.value(for: fields.prompt)
            let answer = item.value(for: fields.answer)
            guard usedIDs.contains(item.id) == false,
                  usedPrompts.contains(prompt) == false,
                  usedAnswers.contains(answer) == false else { continue }
            usedIDs.insert(item.id)
            usedPrompts.insert(prompt)
            usedAnswers.insert(answer)
            pairs.append(MatchingPair(id: item.id, prompt: prompt, answer: answer, hasKanjiForm: item.hasKanjiForm))
            indices.append(index)
        }
        return (pairs, indices)
    }

    // The ticked directions this word can be asked, minus any where its two sides would read
    // identically (a word whose kanji and kana both fall back to the same surface).
    private static func askableDirections(for item: StudyItem, selection: DirectionSelection) -> [QuestionDirection] {
        selection.askable(hasKanjiForm: item.hasKanjiForm).filter { direction in
            item.value(for: direction.fields.prompt) != item.value(for: direction.fields.answer)
        }
    }
}
