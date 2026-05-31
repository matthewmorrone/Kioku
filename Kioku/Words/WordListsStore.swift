import Combine
import Foundation
import SwiftUI

// Owns word-list CRUD for the Words tab. Has no reference to WordsStore — cascade is caller responsibility.
@MainActor
final class WordListsStore: ObservableObject {
    @Published private(set) var lists: [WordList] = []

    private let userDefaults: UserDefaults
    private let storageKey: String

    // UserDefaults and storage key are parameterized so tests scope each case to a
    // per-suite UserDefaults without touching .standard. Production callers get the
    // defaults and keep using the v1 key.
    init(userDefaults: UserDefaults = .standard, storageKey: String = "kioku.wordlists.v1") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        lists = []
        lists = StartupTimer.measure("WordListsStore.init") {
            load()
        }
    }

    // Creates a new word list with the given name and appends it to the published array.
    // Returns the new list's id so callers can immediately target it (e.g. add/move the
    // current selection into the just-created list) without re-searching the array.
    @discardableResult
    func create(name: String) -> UUID {
        let newList = WordList(id: UUID(), name: name, createdAt: Date())
        lists.append(newList)
        persist()
        return newList.id
    }

    // Renames an existing word list by id. No-ops if the id is not found.
    func rename(id: UUID, name: String) {
        guard let index = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[index].name = name
        persist()
    }

    // Deletes a word list by id. Caller must strip orphan memberships from WordsStore.
    func delete(id: UUID) {
        lists.removeAll { $0.id == id }
        persist()
    }

    // Moves one list from one index range to a new position; mirrors SwiftUI's onMove signature.
    func move(from source: IndexSet, to destination: Int) {
        lists.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // Replaces the entire list collection with one deduplicated snapshot.
    func replaceAll(with lists: [WordList]) {
        var seen = Set<UUID>()
        self.lists = lists.filter { seen.insert($0.id).inserted }
        persist()
    }

    // Loads word lists from UserDefaults, returning empty array if none exist.
    private func load() -> [WordList] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WordList].self, from: data) else {
            return []
        }
        return decoded
    }

    // Persists the current lists array to UserDefaults.
    private func persist() {
        guard let encoded = try? JSONEncoder().encode(lists) else { return }
        userDefaults.set(encoded, forKey: storageKey)
    }
}
