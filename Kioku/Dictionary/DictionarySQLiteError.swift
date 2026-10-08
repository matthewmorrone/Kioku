import Foundation

public enum DictionarySQLiteError: Error {
    case databaseNotFound(name: String)
    case openDatabase(message: String)
    case prepareStatement(sql: String, message: String)
    case bindParameter(message: String)
    case step(message: String)
    // A row in the database violates an expected invariant (e.g. a NOT NULL column returned NULL).
    case corruptRow(message: String)

    // Logs the error where it is thrown and returns it, so a failure stays visible even when a
    // caller discards it with `try?` and falls back to an empty result.
    nonisolated func logged() -> DictionarySQLiteError {
        AppLog.error(.dictionary, "[DictionaryStore] \(self)")
        return self
    }
}
