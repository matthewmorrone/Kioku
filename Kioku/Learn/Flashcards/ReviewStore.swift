import Combine
import Foundation

// The per-word "have I learned this?" mark, shown on the star: a checkmark for learned, a
// question mark for not-learned, and the plain star when the user hasn't said either way.
// The two marks are mutually exclusive — setting one clears the other.
enum LearnedState {
    case unmarked
    case learned
    case notLearned
}

// Owns per-word review statistics and the "marked wrong" set for the flashcard system.
// Keyed by canonicalEntryID so history is stable across surface form changes.
// Publishes changes so FlashcardsView and session completion summary can react in real time.
@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var stats: [Int64: ReviewWordStats] = [:]
    @Published private(set) var markedWrong: Set<Int64> = []
    // Words the user has marked "learned" (checkbox instead of star). Set manually via the
    // star long-press menu, or automatically by the auto-learn policy when a correct answer
    // pushes a word over the configured threshold. Keyed by canonicalEntryID like everything else.
    @Published private(set) var learned: Set<Int64> = []
    // Words the user has explicitly marked "not learned" (question mark). The deliberate
    // counterpart to `learned` — distinct from "unmarked", so a word the user has flagged as
    // not-yet-known is its own filterable category. Mutually exclusive with `learned`.
    @Published private(set) var notLearned: Set<Int64> = []
    @Published private(set) var lifetimeCorrect: Int = 0
    @Published private(set) var lifetimeAgain: Int = 0

    private let userDefaults: UserDefaults
    private let statsKey = "kioku.review.stats.v1"
    private let wrongKey = "kioku.review.wrong.v1"
    private let learnedKey = "kioku.review.learned.v1"
    private let notLearnedKey = "kioku.review.notLearned.v1"
    private let lifetimeCorrectKey = "kioku.review.lifetimeCorrect.v1"
    private let lifetimeAgainKey = "kioku.review.lifetimeAgain.v1"

    // UserDefaults is parameterized so tests scope each case to a per-suite store and
    // never collide with .standard. Production callers get the default and keep using
    // the v1 keys above.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        stats = [:]
        markedWrong = []
        learned = []
        notLearned = []
        lifetimeCorrect = 0
        lifetimeAgain = 0
        StartupTimer.measure("ReviewStore.init") {
            load()
        }
    }

    // Records a correct answer: increments counters, clears the wrong flag, and reschedules
    // the card via SRSScheduler so it reappears at the next interval up the ladder.
    func recordCorrect(for id: Int64) {
        let prior = stats[id]
        var st = prior ?? ReviewWordStats(correct: 0, again: 0)
        st.correct += 1
        let now = Date()
        st.lastReviewedAt = now
        let schedule = SRSScheduler.schedule(previous: prior, answer: .correct, now: now)
        st.dueDate = schedule.dueDate
        st.consecutiveCorrect = schedule.consecutiveCorrect
        stats[id] = st
        markedWrong.remove(id)
        lifetimeCorrect += 1
        // Auto-promote to "learned" when this correct answer pushes the word over whatever
        // bar the user configured in Settings. Only acts on a word the user hasn't marked
        // either way (unmarked) — an explicit Learned is already done, and an explicit Not
        // Learned is a deliberate signal we don't override from behind their back.
        if learnedState(for: id) == .unmarked, AutoLearnPolicy.shouldMarkLearned(stats: st) {
            learned.insert(id)
            persistLearned()
        }
        persistStats()
        persistWrong()
        persistLifetime()
    }

    // The current tri-state mark for a word, derived from the two mutually-exclusive sets.
    func learnedState(for id: Int64) -> LearnedState {
        if learned.contains(id) { return .learned }
        if notLearned.contains(id) { return .notLearned }
        return .unmarked
    }

    // Sets the tri-state mark, keeping the two sets mutually exclusive: marking one always
    // clears the other, and .unmarked clears both. The single write path for both the
    // star long-press menu and the auto-learn promotion.
    func setLearnedState(_ state: LearnedState, for id: Int64) {
        switch state {
        case .learned:
            learned.insert(id)
            notLearned.remove(id)
        case .notLearned:
            notLearned.insert(id)
            learned.remove(id)
        case .unmarked:
            learned.remove(id)
            notLearned.remove(id)
        }
        persistLearned()
        persistNotLearned()
    }

    // True when the word has been marked learned (manually or automatically).
    func isLearned(id: Int64) -> Bool {
        learned.contains(id)
    }

    // True when the word has been explicitly marked not-learned.
    func isNotLearned(id: Int64) -> Bool {
        notLearned.contains(id)
    }

    // Records an "again" answer: increments counters, adds the word to the wrong set, resets
    // the SRS streak, and reschedules the card to reappear after the short relearn step.
    func recordAgain(for id: Int64) {
        let prior = stats[id]
        var st = prior ?? ReviewWordStats(correct: 0, again: 0)
        st.again += 1
        let now = Date()
        st.lastReviewedAt = now
        let schedule = SRSScheduler.schedule(previous: prior, answer: .again, now: now)
        st.dueDate = schedule.dueDate
        st.consecutiveCorrect = schedule.consecutiveCorrect
        stats[id] = st
        markedWrong.insert(id)
        lifetimeAgain += 1
        persistStats()
        persistWrong()
        persistLifetime()
    }

    // True when the word is due — never reviewed (no stats) or its `dueDate` has elapsed.
    func isDue(id: Int64, at date: Date = Date()) -> Bool {
        guard let st = stats[id] else { return true }
        guard let due = st.dueDate else { return true }
        return due <= date
    }

    // Number of saved words currently due for review.
    func dueCount(among words: [SavedWord], at date: Date = Date()) -> Int {
        words.reduce(0) { $0 + (isDue(id: $1.canonicalEntryID, at: date) ? 1 : 0) }
    }

    // Overall correct / (correct + again) ratio across all sessions; nil when no reviews recorded.
    var lifetimeAccuracy: Double? {
        let total = lifetimeCorrect + lifetimeAgain
        guard total > 0 else { return nil }
        return Double(lifetimeCorrect) / Double(total)
    }

    // Replaces the entire persisted review snapshot after a validated backup import.
    func replaceAll(
        stats: [Int64: ReviewWordStats],
        markedWrong: Set<Int64>,
        lifetimeCorrect: Int,
        lifetimeAgain: Int,
        learned: Set<Int64> = [],
        notLearned: Set<Int64> = []
    ) {
        self.stats = stats
        self.markedWrong = markedWrong
        self.learned = learned
        self.notLearned = notLearned
        self.lifetimeCorrect = lifetimeCorrect
        self.lifetimeAgain = lifetimeAgain
        persistStats()
        persistWrong()
        persistLearned()
        persistNotLearned()
        persistLifetime()
    }

    // Loads all persisted review state from UserDefaults on init.
    private func load() {
        if let data = userDefaults.data(forKey: statsKey),
           let decoded = try? JSONDecoder().decode([String: ReviewWordStats].self, from: data) {
            var result: [Int64: ReviewWordStats] = [:]
            for (k, v) in decoded {
                if let id = Int64(k) { result[id] = v }
            }
            stats = result
        }

        if let strings = userDefaults.array(forKey: wrongKey) as? [String] {
            markedWrong = Set(strings.compactMap { Int64($0) })
        }

        if let strings = userDefaults.array(forKey: learnedKey) as? [String] {
            learned = Set(strings.compactMap { Int64($0) })
        }

        if let strings = userDefaults.array(forKey: notLearnedKey) as? [String] {
            notLearned = Set(strings.compactMap { Int64($0) })
        }

        lifetimeCorrect = userDefaults.integer(forKey: lifetimeCorrectKey)
        lifetimeAgain = userDefaults.integer(forKey: lifetimeAgainKey)
    }

    // Encodes the stats dictionary with String keys because JSON requires string keys.
    private func persistStats() {
        var encodable: [String: ReviewWordStats] = [:]
        for (id, st) in stats { encodable[String(id)] = st }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        userDefaults.set(data, forKey: statsKey)
    }

    // Persists the wrong set as an array of id strings.
    private func persistWrong() {
        userDefaults.set(markedWrong.map { String($0) }, forKey: wrongKey)
    }

    // Persists the learned set as an array of id strings, mirroring persistWrong.
    private func persistLearned() {
        userDefaults.set(learned.map { String($0) }, forKey: learnedKey)
    }

    // Persists the explicit not-learned set, mirroring persistLearned.
    private func persistNotLearned() {
        userDefaults.set(notLearned.map { String($0) }, forKey: notLearnedKey)
    }

    // Persists lifetime counters as plain integers for cheap reads on subsequent launches.
    private func persistLifetime() {
        userDefaults.set(lifetimeCorrect, forKey: lifetimeCorrectKey)
        userDefaults.set(lifetimeAgain, forKey: lifetimeAgainKey)
    }
}
