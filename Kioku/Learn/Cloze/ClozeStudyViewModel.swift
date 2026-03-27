import Foundation
import NaturalLanguage
import Combine

// Private token representation used only during question construction.
private struct ClozeTokenPick {
    let range: NSRange
    let surface: String
}

// Drives a cloze study session for one note: builds questions, tracks score, and auto-advances.
// Exposes published state consumed by ClozeStudyView.
@MainActor
final class ClozeStudyViewModel: ObservableObject {
    let note: Note

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
        numberOfChoices: Int = 5,
        initialMode: ClozeMode = .random,
        initialBlanksPerSentence: Int = 1,
        excludeDuplicateLines: Bool = true
    ) {
        self.note = note
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

    private func setNewQuestion(_ question: ClozeQuestion) {
        cancelAutoAdvance()
        currentQuestion = question
        selectedOptionByBlankID = [:]
        checkedBlankIDs = []
    }

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
    // fetches embedding-based distractors, and assembles the segment list.
    private func buildQuestion(sentenceIndex: Int, sentenceText: String) async -> ClozeQuestion? {
        let trimmed = sentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let candidates = pickTargetTokens(sentenceText: trimmed)
        let wordCount = candidates.count
        guard wordCount >= 2 else { return nil }

        let desiredBlanks = min(max(1, blanksPerSentence), max(1, wordCount - 1))
        let indices = Array(0..<candidates.count).shuffled()
        let chosen = Array(indices.prefix(desiredBlanks)).sorted()
        guard chosen.isEmpty == false else { return nil }

        var blanksByLocation: [Int: ClozeBlank] = [:]
        for idx in chosen {
            let correct = candidates[idx].surface
            let options = await buildOptions(correct: correct, contextSentence: trimmed)
            guard options.count >= 2 else { return nil }
            blanksByLocation[candidates[idx].range.location] = ClozeBlank(
                id: UUID(), correct: correct, options: options
            )
        }

        let ns = trimmed as NSString
        let tokenRanges = allTokenRanges(sentenceText: trimmed)
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

    // Gathers distractor options using embedding neighbors; falls back to sentence tokens.
    private func buildOptions(correct: String, contextSentence: String) async -> [String] {
        var choices: [String] = [correct]
        choices.reserveCapacity(numberOfChoices)

        if let neighbors = await EmbeddingNeighborsService.shared.neighbors(for: correct, topN: 30) {
            let filtered = neighbors
                .map(\.word)
                .filter { $0 != correct && $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                .filter { isReasonableDistractor(candidate: $0, comparedTo: correct) }
            for w in filtered {
                if choices.count >= numberOfChoices { break }
                if choices.contains(w) == false { choices.append(w) }
            }
        }

        if choices.count < numberOfChoices {
            let fallback = fallbackDistractors(from: contextSentence, excluding: Set(choices))
            for w in fallback {
                if choices.count >= numberOfChoices { break }
                choices.append(w)
            }
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

    // Returns true when the distractor is a plausible length relative to the correct answer.
    private func isReasonableDistractor(candidate: String, comparedTo correct: String) -> Bool {
        let a = (candidate as NSString).length
        let b = (correct as NSString).length
        guard a >= 1, b >= 1, a <= 12 else { return false }
        return Double(max(a, b)) / Double(min(a, b)) <= 2.0
    }

    // Returns up to 12 unique tokens from the sentence as last-resort distractors.
    private func fallbackDistractors(from sentenceText: String, excluding: Set<String>) -> [String] {
        var unique: [String] = []
        var seen: Set<String> = []
        for t in pickTargetTokens(sentenceText: sentenceText).map(\.surface).shuffled() {
            if excluding.contains(t) || seen.contains(t) { continue }
            seen.insert(t)
            unique.append(t)
            if unique.count >= 12 { break }
        }
        return unique
    }

    // Returns Japanese-preferring tokens suitable for blanking; skips pure punctuation.
    private func pickTargetTokens(sentenceText: String) -> [ClozeTokenPick] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentenceText
        tokenizer.setLanguage(.japanese)

        var picks: [ClozeTokenPick] = []
        tokenizer.enumerateTokens(in: sentenceText.startIndex..<sentenceText.endIndex) { range, _ in
            let nsRange = NSRange(range, in: sentenceText)
            guard nsRange.length > 0 else { return true }
            let surface = (sentenceText as NSString).substring(with: nsRange)
            let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, isMostlyPunctuation(trimmed) == false else { return true }
            picks.append(ClozeTokenPick(range: nsRange, surface: surface))
            return true
        }

        let japanese = picks.filter { containsJapanese($0.surface) }
        return japanese.isEmpty ? picks : japanese
    }

    // Returns all token ranges in document order, used for segment construction.
    private func allTokenRanges(sentenceText: String) -> [ClozeTokenPick] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentenceText
        tokenizer.setLanguage(.japanese)

        var tokens: [ClozeTokenPick] = []
        tokenizer.enumerateTokens(in: sentenceText.startIndex..<sentenceText.endIndex) { range, _ in
            let nsRange = NSRange(range, in: sentenceText)
            guard nsRange.length > 0 else { return true }
            tokens.append(ClozeTokenPick(
                range: nsRange,
                surface: (sentenceText as NSString).substring(with: nsRange)
            ))
            return true
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    private func isMostlyPunctuation(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        guard scalars.isEmpty == false else { return true }
        let punctCount = scalars.filter { CharacterSet.punctuationCharacters.contains($0) }.count
        return punctCount == scalars.count
    }

    private func containsJapanese(_ string: String) -> Bool {
        string.unicodeScalars.contains { s in
            switch s.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF: return true
            default: return false
            }
        }
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
