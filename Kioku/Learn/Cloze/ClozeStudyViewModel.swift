import Foundation
import NaturalLanguage
import Combine

// Private token representation used only during question construction. `lemma` is the segmenter's
// dictionary form for the token, nil when it had none or the sentence was split without a segmenter.
nonisolated private struct ClozeTokenPick: Sendable {
    let range: NSRange
    let surface: String
    let lemma: String?
}

// Drives a cloze study session for one note: builds questions, tracks score, and auto-advances.
// Exposes published state consumed by ClozeStudyView.
@MainActor
final class ClozeStudyViewModel: ObservableObject {
    let note: Note
    private let dictionaryStore: DictionaryStore?
    // The Read tab's segmenter, so blanks are whole words (食べた, not 食べ + た); NLTokenizer without it.
    private let segmenter: (any TextSegmenting)?
    // Inflects verb and adjective distractors the way the blank is inflected.
    private let lexicon: Lexicon?
    // The dictionary-wide distractor pool Multiple Choice also uses, fetched on first need.
    private var dictionaryPool: [StudyField: [DistractorCandidate]]?
    // The same pool's raw rows that conjugate, with their POS tags, for inflected blanks.
    private var conjugatingPoolRows: [DictionaryDistractorRow]?

    @Published var mode: ClozeMode
    @Published private(set) var sentenceCount: Int = 0
    @Published var blanksPerSentence: Int = 1
    @Published private(set) var isLoading = false
    @Published private(set) var currentQuestion: ClozeQuestion? = nil
    @Published private(set) var selectedOptionByBlankID: [UUID: String] = [:]
    @Published private(set) var checkedBlankIDs: Set<UUID> = []
    @Published private(set) var correctCount = 0
    @Published private(set) var totalCount = 0

    private let sentences: [String]
    private var sequentialIndex = 0
    private var remainingRandomIndices: [Int] = []
    private let numberOfChoices: Int
    private var pendingAutoAdvanceTask: Task<Void, Never>? = nil
    private let autoAdvanceDelayNanoseconds: UInt64 = 3_000_000_000

    // Initialises a session for the given note with configurable blank count and ordering.
    init(
        note: Note,
        dictionaryStore: DictionaryStore?,
        segmenter: (any TextSegmenting)?,
        lexicon: Lexicon?,
        numberOfChoices: Int = 5,
        initialMode: ClozeMode = .random,
        initialBlanksPerSentence: Int = 1,
        excludeDuplicateLines: Bool = true
    ) {
        self.note = note
        self.dictionaryStore = dictionaryStore
        self.segmenter = segmenter
        self.lexicon = lexicon
        self.numberOfChoices = max(2, min(8, numberOfChoices))
        self.mode = initialMode
        self.blanksPerSentence = max(1, initialBlanksPerSentence)
        // Note.content is the canonical text field in Kioku (Kyouku used .text).
        self.sentences = Self.sentences(from: note.content, excludeDuplicateLines: excludeDuplicateLines)
        self.sentenceCount = sentences.count
        resetRandomBag()
    }

    // Kicks off the first question. Called from ClozeStudyView.onAppear.
    func start() {
        Task { await nextQuestion() }
    }

    // Advances to the next sentence, picking the index according to the current mode.
    func nextQuestion() async {
        cancelAutoAdvance()
        guard sentences.isEmpty == false else { currentQuestion = nil; return }

        isLoading = true
        defer { isLoading = false }

        let sentenceIndex: Int
        switch mode {
        case .sequential:
            if sequentialIndex >= sentences.count { sequentialIndex = 0 }
            sentenceIndex = sequentialIndex
            sequentialIndex += 1
        case .random:
            if remainingRandomIndices.isEmpty { resetRandomBag() }
            sentenceIndex = remainingRandomIndices.removeLast()
        }

        let text = sentences[sentenceIndex]
        if let question = await buildQuestion(sentenceIndex: sentenceIndex, sentenceText: text) {
            setNewQuestion(question)
            return
        }

        // Retry up to 4 times with random fallback sentences when construction fails.
        for _ in 0..<4 {
            let fallback = Int.random(in: 0..<sentences.count)
            if let q = await buildQuestion(sentenceIndex: fallback, sentenceText: sentences[fallback]) {
                setNewQuestion(q)
                return
            }
        }
        currentQuestion = nil
    }

    // Records the user's selection for a blank and checks correctness immediately.
    func submitSelection(blankID: UUID, option: String) {
        guard let q = currentQuestion else { return }
        guard q.blanks.contains(where: { $0.id == blankID }) else { return }

        selectedOptionByBlankID[blankID] = option
        if checkedBlankIDs.contains(blankID) == false {
            checkedBlankIDs.insert(blankID)
            totalCount += 1
            if q.blanks.first(where: { $0.id == blankID })?.correct == option {
                correctCount += 1
            }
        }
        scheduleAutoAdvanceIfComplete(question: q)
    }

    // Fills all unanswered blanks with the correct answer (counts as incorrect for each).
    func revealAnswer() {
        guard let q = currentQuestion else { return }
        for blank in q.blanks {
            guard checkedBlankIDs.contains(blank.id) == false else { continue }
            selectedOptionByBlankID[blank.id] = blank.correct
            checkedBlankIDs.insert(blank.id)
            totalCount += 1
            // Intentional: reveal does not award correctCount points.
        }
        scheduleAutoAdvanceIfComplete(question: q)
    }

    // Rebuilds the current sentence's question with the updated blanksPerSentence count.
    func rebuildCurrentQuestion() {
        guard let q = currentQuestion else { return }
        cancelAutoAdvance()
        Task {
            if let rebuilt = await buildQuestion(sentenceIndex: q.sentenceIndex, sentenceText: q.sentenceText) {
                setNewQuestion(rebuilt)
            }
        }
    }

    // Applies a new question to the view model, resetting all answer state so the UI shows a fresh card.
    private func setNewQuestion(_ question: ClozeQuestion) {
        cancelAutoAdvance()
        currentQuestion = question
        selectedOptionByBlankID = [:]
        checkedBlankIDs = []
    }

    // Cancels any pending auto-advance so navigating manually does not trigger a redundant transition.
    private func cancelAutoAdvance() {
        pendingAutoAdvanceTask?.cancel()
        pendingAutoAdvanceTask = nil
    }

    // Schedules auto-advance 3 s after all blanks in the current question are answered.
    private func scheduleAutoAdvanceIfComplete(question: ClozeQuestion) {
        guard checkedBlankIDs.count >= question.blanks.count else { return }
        let questionID = question.id
        pendingAutoAdvanceTask?.cancel()
        pendingAutoAdvanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.autoAdvanceDelayNanoseconds)
            guard Task.isCancelled == false, self.currentQuestion?.id == questionID else { return }
            await self.nextQuestion()
        }
    }

    // Shuffles the sentence index pool so every sentence is seen before any repeats.
    private func resetRandomBag() {
        remainingRandomIndices = Array(0..<sentences.count).shuffled()
    }

    // Constructs a ClozeQuestion for one sentence: tokenises, picks blank targets,
    // gathers distractors (see buildOptions), and assembles the segment list.
    private func buildQuestion(sentenceIndex: Int, sentenceText: String) async -> ClozeQuestion? {
        let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let tokens = await tokenize(trimmed)
        let candidates = blankCandidates(from: tokens)
        let wordCount = candidates.count
        guard wordCount >= 2 else { return nil }

        let desiredBlanks = min(max(1, blanksPerSentence), max(1, wordCount - 1))
        let indices = Array(0..<candidates.count).shuffled()
        let chosen = Array(indices.prefix(desiredBlanks)).sorted()
        guard chosen.isEmpty == false else { return nil }

        var blanksByLocation: [Int: ClozeBlank] = [:]
        for idx in chosen {
            let correct = candidates[idx].surface
            let options = await buildOptions(for: candidates[idx], sentenceCandidates: candidates)
            guard options.count >= 2 else { return nil }
            blanksByLocation[candidates[idx].range.location] = ClozeBlank(
                id: UUID(), correct: correct, options: options
            )
        }

        let ns = trimmed as NSString
        let tokenRanges = tokens
        guard tokenRanges.isEmpty == false else { return nil }

        var segments: [ClozeSegment] = []
        segments.reserveCapacity(tokenRanges.count * 2)

        var cursor = 0
        for token in tokenRanges {
            if token.range.location > cursor {
                let gap = ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
                if gap.isEmpty == false {
                    segments.append(ClozeSegment(id: UUID(), kind: .text(gap)))
                }
            }
            if let blank = blanksByLocation[token.range.location] {
                segments.append(ClozeSegment(id: UUID(), kind: .blank(blank)))
            } else {
                segments.append(ClozeSegment(id: UUID(), kind: .text(token.surface)))
            }
            cursor = NSMaxRange(token.range)
        }

        let len = ns.length
        if cursor < len {
            let tail = ns.substring(with: NSRange(location: cursor, length: len - cursor))
            if tail.isEmpty == false {
                segments.append(ClozeSegment(id: UUID(), kind: .text(tail)))
            }
        }

        let blanks = segments.compactMap { seg -> ClozeBlank? in
            if case let .blank(b) = seg.kind { return b }
            return nil
        }
        guard blanks.isEmpty == false else { return nil }

        return ClozeQuestion(
            id: UUID(),
            sentenceIndex: sentenceIndex,
            sentenceText: trimmed,
            wordCount: wordCount,
            segments: segments,
            blanks: blanks
        )
    }

    // Gathers distractor options: for an inflected verb or adjective, dictionary words of its exact
    // conjugation class inflected the same way; for a dictionary headword, same-script dictionary
    // words ranked by word class; topped up with the sentence's other words either way.
    private func buildOptions(for blank: ClozeTokenPick, sentenceCandidates: [ClozeTokenPick]) async -> [String] {
        let correct = blank.surface
        var choices: [String] = [correct]
        choices.reserveCapacity(numberOfChoices)

        var dictionaryOptions = await inflectedDistractors(for: blank, count: numberOfChoices - 1)
        if dictionaryOptions.isEmpty {
            dictionaryOptions = await dictionaryDistractors(for: correct, count: numberOfChoices - 1)
        }
        for w in dictionaryOptions where choices.contains(w) == false {
            choices.append(w)
        }
        for w in fallbackDistractors(from: sentenceCandidates, excluding: Set(choices)) {
            if choices.count >= numberOfChoices { break }
            choices.append(w)
        }

        // Pad with an ellipsis token so there are always at least 2 options.
        while choices.count < min(numberOfChoices, 3) {
            let token = "…"
            if choices.contains(token) == false { choices.append(token) }
            break
        }

        choices = Array(choices.prefix(numberOfChoices)).shuffled()
        if choices.contains(correct) == false {
            if choices.isEmpty { choices = [correct] }
            else { choices[0] = correct; choices.shuffle() }
        }
        return choices
    }

    // Dictionary verbs/adjectives of the blank's exact conjugation class, inflected along the blank's
    // own rule path (食べた → 見た, 寝た). Empty when the blank isn't an inflected form or no lexicon.
    private func inflectedDistractors(for blank: ClozeTokenPick, count: Int) async -> [String] {
        guard let lexicon, let lemma = blank.lemma, lemma != blank.surface, count > 0 else { return [] }
        if conjugatingPoolRows == nil, let store = dictionaryStore {
            conjugatingPoolRows = await Task.detached(priority: .utility) {
                // fetchDistractorPool logs its own failures; an empty pool falls back to sentence words.
                ((try? store.fetchDistractorPool()) ?? []).filter {
                    ConjugationClass.conjugatingTags(in: $0.posTags).isEmpty == false
                }
            }.value
        }
        let useKanji = ScriptClassifier.containsKanji(blank.surface)
        let candidates = (conjugatingPoolRows ?? []).compactMap { row -> (text: String, posTags: [String])? in
            guard let text = useKanji ? row.kanji : row.kana else { return nil }
            return (text: text, posTags: row.posTags)
        }.shuffled()
        return lexicon.inflectLike(surface: blank.surface, lemma: lemma, candidates: candidates, limit: count)
    }

    // Same-script words from the dictionary-wide pool, ranked toward the blank's word class as
    // Multiple Choice ranks them. Only for a blank that is itself a headword: an inflected or partial
    // token (食べ, なかった) would stand out against dictionary-form rivals, so it gets none.
    private func dictionaryDistractors(for surface: String, count: Int) async -> [String] {
        guard let store = dictionaryStore, count > 0 else { return [] }
        let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wordClass = await Task.detached(priority: .userInitiated, operation: {
            Self.headwordClass(of: trimmed, store: store)
        }).value else { return [] }
        if dictionaryPool == nil {
            dictionaryPool = await LearnWordPool.fetchDictionaryDistractorPool(dictionaryStore: store)
        }
        let field: StudyField = ScriptClassifier.containsKanji(trimmed) ? .kanji : .kana
        let pool = (dictionaryPool?[field] ?? []).filter { $0.text != trimmed }.shuffled()
        return DistractorSelector.choose(
            from: pool,
            answer: DistractorCandidate(text: trimmed, wordClass: wordClass),
            prompt: "",
            count: count
        )
    }

    // The word class of the entry listing `surface` verbatim as a kanji or kana form, or nil when no
    // entry does (lookup's variant expansion would otherwise admit near-spellings).
    private nonisolated static func headwordClass(of surface: String, store: DictionaryStore) -> WordClass? {
        guard surface.isEmpty == false,
              let entries = try? store.lookup(surface: surface, mode: .kanjiAndKana),
              let entry = entries.first(where: { entry in
                  entry.kanjiForms.contains { $0.text == surface } || entry.kanaForms.contains { $0.text == surface }
              }) else { return nil }
        let posTags = entry.senses
            .compactMap(\.pos)
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        return WordClass.from(posTags: posTags)
    }

    // Returns up to 12 unique words from the sentence as distractors.
    private func fallbackDistractors(from sentenceCandidates: [ClozeTokenPick], excluding: Set<String>) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for t in sentenceCandidates.map(\.surface).shuffled() {
            if excluding.contains(t) || seen.contains(t) { continue }
            seen.insert(t)
            unique.append(t)
            if unique.count >= 12 { break }
        }
        return unique
    }

    // Splits a sentence into words in document order: with the Read tab's segmenter when there is
    // one (off the main actor; whole inflected words, each with its lemma), else with NLTokenizer.
    private func tokenize(_ sentenceText: String) async -> [ClozeTokenPick] {
        guard let segmenter else { return Self.nlTokens(sentenceText) }
        let tokens = await Task.detached(priority: .userInitiated) {
            segmenter.longestMatchEdges(for: sentenceText).map { edge in
                ClozeTokenPick(
                    range: NSRange(edge.start..<edge.end, in: sentenceText),
                    surface: edge.surface,
                    lemma: edge.lemma.isEmpty ? nil : edge.lemma
                )
            }
        }.value
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // NLTokenizer's word split, for when the dictionary (and so the segmenter) isn't installed.
    private static func nlTokens(_ sentenceText: String) -> [ClozeTokenPick] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentenceText
        tokenizer.setLanguage(.japanese)

        var tokens: [ClozeTokenPick] = []
        tokenizer.enumerateTokens(in: sentenceText.startIndex..<sentenceText.endIndex) { range, _ in
            let nsRange = NSRange(range, in: sentenceText)
            guard nsRange.length > 0 else { return true }
            tokens.append(ClozeTokenPick(
                range: nsRange,
                surface: (sentenceText as NSString).substring(with: nsRange),
                lemma: nil
            ))
            return true
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    // The words worth blanking: no whitespace- or punctuation-only tokens, and Japanese ones when
    // the sentence has any.
    private func blankCandidates(from tokens: [ClozeTokenPick]) -> [ClozeTokenPick] {
        let picks = tokens.filter { token in
            let trimmed = token.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty == false && isMostlyPunctuation(trimmed) == false
        }
        let japanese = picks.filter { containsJapanese($0.surface) }
        return japanese.isEmpty ? picks : japanese
    }

    // Filters out punctuation-only tokens so they are never chosen as cloze blanks.
    private func isMostlyPunctuation(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        guard scalars.isEmpty == false else { return true }
        let punctCount = scalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
        return punctCount == scalars.count
    }

    // Guards that a candidate sentence has at least some Japanese script before building a question from it.
    private func containsJapanese(_ string: String) -> Bool {
        ScriptClassifier.containsJapanese(string)
    }

    // Splits note text into sentences using SentenceRangeResolver, optionally deduplicating lines.
    private static func sentences(from text: String, excludeDuplicateLines: Bool) -> [String] {
        let ns = text as NSString
        let ranges = SentenceRangeResolver.sentenceRanges(in: ns)
        guard ranges.isEmpty == false else { return [] }

        var out: [String] = []
        out.reserveCapacity(ranges.count)
        var seen: Set<String> = []

        for r in ranges {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= ns.length else { continue }
            let s = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.isEmpty == false else { continue }
            if excludeDuplicateLines {
                if seen.contains(s) { continue }
                seen.insert(s)
            }
            out.append(s)
        }
        return out
    }
}
