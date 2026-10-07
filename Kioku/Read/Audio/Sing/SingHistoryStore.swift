import Foundation

// Keeps finished Sing sessions per song note so the summary can show how earlier runs went.
// Newest first, capped per note; stored as one JSON blob in UserDefaults. Independent of the
// note's lifecycle and of saved words.
final class SingHistoryStore {
    static let shared = SingHistoryStore()
    static let maximumPerNote = 50

    private let defaults: UserDefaults
    private let storageKey = "kioku.sing.history"

    // Takes the defaults to persist into so tests can use an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // The note's sessions, newest first.
    func sessions(for noteID: UUID) -> [SingSessionRecord] {
        all().filter { $0.noteID == noteID }.sorted { $0.date > $1.date }
    }

    // Records a finished session, dropping the note's oldest beyond the cap. Sessions where
    // nothing was graded aren't kept.
    func append(_ record: SingSessionRecord) {
        guard record.gradedCount > 0 else { return }
        var records = all()
        records.append(record)
        let mine = records.filter { $0.noteID == record.noteID }.sorted { $0.date > $1.date }
        if mine.count > Self.maximumPerNote {
            let dropped = Set(mine.dropFirst(Self.maximumPerNote).map(\.date))
            records.removeAll { $0.noteID == record.noteID && dropped.contains($0.date) }
        }
        UserDefaultsJSON.save(records, forKey: storageKey, to: defaults, logAs: .audioPlayback)
    }

    // Every stored session across notes.
    private func all() -> [SingSessionRecord] {
        UserDefaultsJSON.load([SingSessionRecord].self, forKey: storageKey, from: defaults, logAs: .audioPlayback) ?? []
    }
}
