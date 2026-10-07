import Foundation
import SQLite3

// Proper names from JMnedict (name_entries / name_forms, written by generate_db.py's import_names).
// Kept apart from the word tables: nothing here reaches the trie or the segmenter.
extension DictionaryStore {
    // Upper bound on names returned for one surface; common kanji pairs (田中) carry a dozen rare
    // readings beyond the few the sheet has room for.
    nonisolated static let maxNamesPerSurface = 6

    // The name readings JMnedict gives for `surface` (and its spelling variants, as word lookup
    // tries them), in JMnedict's order, so the lookup sheet can say "たなか · surname" for a word
    // JMdict doesn't have. Empty for a dictionary built before the name tables existed.
    nonisolated func lookupNames(surface: String) throws -> [DictionaryName] {
        try withSerializedDatabaseAccess {
            guard tableExists("name_forms") else { return [] }
            let sql = """
                SELECT f.reading, e.types, e.gloss
                FROM name_forms f JOIN name_entries e ON e.id = f.entry_id
                WHERE f.surface = ?1
                ORDER BY e.id
                LIMIT \(Self.maxNamesPerSurface)
                """
            for candidate in lookupSurfaces(for: surface) {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare(sql: sql, statement: &statement)
                try bindText(candidate, index: 1, statement: statement)
                var names: [DictionaryName] = []
                var stepCode = sqlite3_step(statement)
                while stepCode == SQLITE_ROW {
                    let reading = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                    let types = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                    let gloss = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                    names.append(DictionaryName(
                        reading: reading,
                        types: types.split(separator: ",").map(String.init),
                        gloss: gloss
                    ))
                    stepCode = sqlite3_step(statement)
                }
                guard stepCode == SQLITE_DONE else {
                    throw DictionarySQLiteError.step(message: errorMessage())
                }
                if names.isEmpty == false { return names }
            }
            return []
        }
    }

    // Plain-English label for a JMnedict name type tag, for the lookup sheet ("fem" → "female given
    // name"). Unlisted tags fall back to the tag itself.
    nonisolated static func nameTypeLabel(_ tag: String) -> String {
        switch tag {
        case "surname": return "surname"
        case "place": return "place"
        case "given": return "given name"
        case "fem": return "female given name"
        case "masc": return "male given name"
        case "person": return "person"
        case "station": return "railway station"
        case "company": return "company"
        case "organization": return "organization"
        case "product": return "product"
        case "work": return "work title"
        case "char": return "character"
        case "fict": return "fictional"
        case "group": return "group"
        case "serv": return "service"
        case "ev": return "event"
        case "obj": return "object"
        case "myth": return "mythology"
        case "dei": return "deity"
        case "relig": return "religion"
        case "leg": return "legend"
        case "creat": return "creature"
        case "ship": return "ship"
        case "doc": return "document"
        case "unclass": return "name"
        default: return tag
        }
    }
}
