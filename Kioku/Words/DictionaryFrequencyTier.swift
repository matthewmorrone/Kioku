import Foundation

// Frequency-rank threshold for live dictionary search: keeps only entries whose JPDB usage rank
// (lower = more frequent) falls within the tier. Distinct from the JMdict-based "Common Words
// Only" toggle — that's a coarse editorial flag, this is a finer usage-frequency cutoff. `.any`
// disables the filter.
enum DictionaryFrequencyTier: String, CaseIterable, Identifiable {
    case any
    case top5k
    case top10k
    case top20k

    var id: String { rawValue }

    // Inclusive JPDB-rank cap; nil means no frequency filtering. Entries with no JPDB rank are
    // excluded whenever a cap is set (unranked ⇒ not among the most-frequent words).
    var maxRank: Int? {
        switch self {
        case .any: return nil
        case .top5k: return 5_000
        case .top10k: return 10_000
        case .top20k: return 20_000
        }
    }

    // Human-readable menu label for the Words search controls.
    var title: String {
        switch self {
        case .any: return "Any Frequency"
        case .top5k: return "Top 5,000"
        case .top10k: return "Top 10,000"
        case .top20k: return "Top 20,000"
        }
    }
}
