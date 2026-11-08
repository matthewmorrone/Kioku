import Foundation
import Combine

// Dictionary entries for the saved and history rows of the Words tab, held outside the view so they
// can be loaded at launch. Without it the tab fetched them only after first appearing, and its rows
// showed no definition or reading for a moment.
@MainActor
final class WordEntryCache: ObservableObject {
    static let shared = WordEntryCache()

    // True once the launch preload has finished (or can't happen); the Words tab stays covered until
    // then so it never shows rows without their definitions.
    @Published private(set) var isReady = false

    // Lifts the Words tab's cover. Called when the preload finishes, when there is no dictionary to
    // preload from, or when the preload takes too long.
    func markReady() {
        isReady = true
    }

    // Entries keyed by canonical entry id; what the Words tab starts from.
    private(set) var entries: [Int64: DictionaryEntry] = [:]

    // Kanji info for the Saved tab's kanji tiles, keyed by literal.
    private(set) var kanji: [String: KanjiInfo] = [:]

    // Adds freshly loaded kanji info.
    func mergeKanji(_ loaded: [String: KanjiInfo]) {
        kanji.merge(loaded) { _, new in new }
    }

    // Loads the info for the given saved kanji that isn't cached yet, off the main thread. A literal
    // that fails to load is logged and left for the Words tab to load when it opens.
    func warmKanji(store: DictionaryStore, literals: [String]) async {
        let missing = Array(Set(literals)).filter { kanji[$0] == nil }
        guard missing.isEmpty == false else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> [String: KanjiInfo] in
            var result: [String: KanjiInfo] = [:]
            for literal in missing {
                do {
                    if let info = try store.fetchKanjiInfo(for: literal) { result[literal] = info }
                } catch {
                    AppLog.error(.dictionary, "kanji cache warm failed for \(literal) — \(error.localizedDescription)")
                }
            }
            return result
        }.value
        mergeKanji(loaded)
    }

    // Adds freshly loaded entries so later tab openings, and the tab itself, start with them.
    func merge(_ loaded: [DictionaryEntry]) {
        for entry in loaded { entries[entry.entryId] = entry }
    }

    // Loads the entries for the given ids that aren't cached yet, off the main thread. A failed lookup
    // is logged and leaves the Words tab to load them when it opens.
    func warm(store: DictionaryStore, entryIDs: [Int64]) async {
        let missing = Array(Set(entryIDs)).filter { entries[$0] == nil }
        guard missing.isEmpty == false else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> [DictionaryEntry] in
            do {
                return try store.lookupEntries(entryIDs: missing)
            } catch {
                AppLog.error(.dictionary, "entry cache warm failed — \(error.localizedDescription)")
                return []
            }
        }.value
        merge(loaded)
    }
}
