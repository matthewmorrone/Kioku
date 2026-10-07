import Foundation
import SQLite3

// Proper names from JMnedict (name_entries / name_forms, written by generate_db.py's import_names).
// Kept apart from the word tables: nothing here reaches the trie or the segmenter.
extension DictionaryStore {
    // Upper bound on names returned for one surface; common kanji pairs (田中) carry a dozen rare
    // readings beyond the few the sheet has room for.
    nonisolated static let maxNamesPerSurface = 6

    // The name readings JMnedict gives for `surface` (and its spelling variants, as word lookup
    // tries them), the usual reading first (name_forms.rank), so the lookup sheet can say "たなか · surname" for a word
    // JMdict doesn't have. Empty for a dictionary built before the name tables existed.
    nonisolated func lookupNames(surface: String) throws -> [DictionaryName] {
        try withSerializedDatabaseAccess {
            guard tableExists("name_forms") else { return [] }
            let sql = """
                SELECT f.reading, e.types, e.gloss, f.rank
                FROM name_forms f JOIN name_entries e ON e.id = f.entry_id
                WHERE f.surface = ?1
                ORDER BY f.rank, e.id
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
                        gloss: gloss,
                        isUsualReading: sqlite3_column_int(statement, 3) == 0
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

    // The name spellings the segmenter may use as words (Segmenter.nameSurfaces): two or more
    // characters, no hiragana, and some kanji or all katakana. Single characters (中, 森) and
    // hiragana names (まこと, あい) are nearly always ordinary words in running text, so they stay
    // out. So does a name that splits into another name plus a dictionary suffix when none of its
    // readings is the usual one (name_forms.rank): 森氏 is only もりうじ, but in running text it is
    // 森 + 氏 (Mr. Mori). 田中 (田 + the suffix 中) and 富良野市 keep their usual reading, so they stay.
    // Empty for a dictionary built before the name tables existed.
    nonisolated func fetchSegmenterNameSurfaces() throws -> Set<String> {
        try withSerializedDatabaseAccess {
            guard tableExists("name_forms") else { return [] }
            let allNames = try fetchTextColumn(sql: "SELECT DISTINCT surface FROM name_forms")
            let suffixes = try fetchTextColumn(sql: """
                SELECT DISTINCT k.text FROM kanji k JOIN senses s ON s.entry_id = k.entry_id
                WHERE s.pos LIKE '%suf%'
                """)
            let usualNames = try fetchTextColumn(sql: "SELECT DISTINCT surface FROM name_forms WHERE rank = 0")
            // Whether `surface` splits into a name and a dictionary suffix (森 + 氏).
            func isNamePlusSuffix(_ surface: String) -> Bool {
                (1..<surface.count).contains { split in
                    let cut = surface.index(surface.startIndex, offsetBy: split)
                    return suffixes.contains(String(surface[cut...])) && allNames.contains(String(surface[..<cut]))
                }
            }
            return allNames.filter { surface in
                surface.count >= 2
                    && surface.unicodeScalars.contains(where: { (0x3041...0x309F).contains($0.value) }) == false
                    && (ScriptClassifier.containsKanji(surface) || ScriptClassifier.isPureKatakana(surface))
                    && (usualNames.contains(surface) || isNamePlusSuffix(surface) == false)
            }
        }
    }

    // Every non-null text value of a one-column query, as a set. Caller holds the database queue.
    private nonisolated func fetchTextColumn(sql: String) throws -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql: sql, statement: &statement)
        var values = Set<String>()
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 0) {
                values.insert(String(cString: pointer))
            }
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }
        return values
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
