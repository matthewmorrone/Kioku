import Combine
import Foundation

// Owns per-word review statistics and the "marked wrong" set for the flashcard system.
// Keyed by canonicalEntryID so history is stable across surface form changes.
// Publishes changes so FlashcardsView and session completion summary can react in real time.
@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var stats: [Int64: ReviewWordStats] = [:]
    @Published private(set) var markedWrong: Set<Int64> = []
    @Published private(set) var lifetimeCorrect: Int = 0
    @Published private(set) var lifetimeAgain: Int = 0

    private let statsKey = "kioku.review.stats.v1"
    private let wrongKey = "kioku.review.wrong.v1"
    private let lifetimeCorrectKey = "kioku.review.lifetimeCorrect.v1"
    private let lifetimeAgainKey = "kioku.review.lifetimeAgain.v1"

    init() {
        load()
    }

    // Records a correct answer: increments the per-word correct counter, clears the wrong
    // flag, and bumps the lifetime correct count.
    func recordCorrect(for id: Int64) {
        var st = stats[id] ?? ReviewWordStats(correct: 0, again: 0)
        st.correct += 1
        st.lastReviewedAt = Date()
        stats[id] = st
        markedWrong.remove(id)
        lifetimeCorrect += 1
        persistStats()
        persistWrong()
        persistLifetime()
    }

    // Records an "again" answer: increments the per-word again counter, adds the word to
    // the wrong set so it shows up in the "Marked Wrong" scope, and bumps the lifetime again count.
    func recordAgain(for id: Int64) {
        var st = stats[id] ?? ReviewWordStats(correct: 0, again: 0)
        st.again += 1
        st.lastReviewedAt = Date()
        stats[id] = st
        markedWrong.insert(id)
        lifetimeAgain += 1
        persistStats()
        persistWrong()
        persistLifetime()
    }

    // Overall correct / (correct + again) ratio across all sessions; nil when no reviews recorded.
    var lifetimeAccuracy: Double? {
        let total = lifetimeCorrect + lifetimeAgain
        guard total > 0 else { return nil }
        return Double(lifetimeCorrect) / Double(total)
    }

    // Loads all persisted review state from UserDefaults on init.
    private func load() {
        if let data = UserDefaults.standard.data(forKey: statsKey),
           let decoded = try? JSONDecoder().decode([String: ReviewWordStats].self, from: data) {
            var result: [Int64: ReviewWordStats] = [:]
            for (k, v) in decoded {
                if let id = Int64(k) { result[id] = v }
            }
            stats = result
        }

        if let strings = UserDefaults.standard.array(forKey: wrongKey) as? [String] {
            markedWrong = Set(strings.compactMap { Int64($0) })
        }

        lifetimeCorrect = UserDefaults.standard.integer(forKey: lifetimeCorrectKey)
        lifetimeAgain = UserDefaults.standard.integer(forKey: lifetimeAgainKey)
    }

    // Encodes the stats dictionary with String keys because JSON requires string keys.
    private func persistStats() {
        var encodable: [String: ReviewWordStats] = [:]
        for (id, st) in stats { encodable[String(id)] = st }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: statsKey)
    }

    // Persists the wrong set as an array of id strings.
    private func persistWrong() {
        UserDefaults.standard.set(markedWrong.map { String($0) }, forKey: wrongKey)
    }

    // Persists lifetime counters as plain integers for cheap reads on subsequent launches.
    private func persistLifetime() {
        UserDefaults.standard.set(lifetimeCorrect, forKey: lifetimeCorrectKey)
        UserDefaults.standard.set(lifetimeAgain, forKey: lifetimeAgainKey)
    }
}
