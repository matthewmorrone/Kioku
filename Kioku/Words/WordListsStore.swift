import Combine
import Foundation

// Owns word-list CRUD for the Words tab. Has no reference to WordsStore — cascade is caller responsibility.
@MainActor
final class WordListsStore: ObservableObject {
    @Published private(set) var lists: [WordList] = []

    private let storageKey = "kioku.wordlists.v1"

    init() {
        lists = []
        lists = StartupTimer.measure("WordListsStore.init") {
            load()
        }
    }

    // Creates a new word list with the given name and appends it to the published array.
    func create(name: String) {
        let newList = WordList(id: UUID(), name: name, createdAt: Date())
        lists.append(newList)
        persist()
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

    // Replaces the entire list collection with one deduplicated snapshot.
    func replaceAll(with lists: [WordList]) {
        var seen = Set<UUID>()
        self.lists = lists.filter { seen.insert($0.id).inserted }
        persist()
    }

    // Loads word lists from UserDefaults, returning empty array if none exist.
    private func load() -> [WordList] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WordList].self, from: data) else {
            return []
        }
        return decoded
    }

    // Persists the current lists array to UserDefaults.
    private func persist() {
        guard let encoded = try? JSONEncoder().encode(lists) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
}
