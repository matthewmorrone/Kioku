import Foundation
import SQLite3

// Candidate entries for a spelling the dictionary lacks, for the custom-word editor's Suggestions.
// Two kinds of near miss, each found in one scan with GLOB patterns:
//   • kanji spellings — one kanji swapped for another, same kana around it (馳け寄 → 駆け寄る): each
//     kanji up to the last one becomes `?`, anything may follow;
//   • kana spellings — one edit away (カステイラ → カステラ, ウエファース → ウエハース): a character
//     dropped, replaced, inserted, or two merged into one.
// Ranked by frequency, most common first.
extension DictionaryStore {
    // Up to `limit` suggestions for `spelling`; empty for spellings too short to pattern-match.
    nonisolated func spellingSuggestions(for spelling: String, limit: Int = 12) throws -> [SpellingSuggestion] {
        let characters = Array(spelling)
        if ScriptClassifier.containsKanji(spelling) {
            return try kanjiSwapSuggestions(characters, limit: limit)
        }
        return try kanaEditSuggestions(characters, limit: limit)
    }

    // Kanji spellings: one kanji replaced, kana kept. The stored spelling puts the user's kanji back
    // into the matched form and keeps the form's own ending (dictionary form, not the inflection).
    nonisolated private func kanjiSwapSuggestions(_ characters: [Character], limit: Int) throws -> [SpellingSuggestion] {
        guard let lastKanji = characters.lastIndex(where: { ScriptClassifier.containsKanji(String($0)) }) else { return [] }
        let stem = Array(characters[...lastKanji])
        guard stem.count >= 2 else { return [] }
        let kanjiPositions = stem.indices.filter { ScriptClassifier.containsKanji(String(stem[$0])) }
        let patterns = kanjiPositions.map { position -> String in
            var pattern = stem.map { String($0) }
            pattern[position] = "?"
            return pattern.joined() + "*"
        }
        let matches = try formsMatching(patterns: patterns, table: "kanji")
        let original = String(characters)
        let suggestions = matches.compactMap { match -> SpellingSuggestion? in
            var form = Array(match.text)
            guard form.count >= stem.count else { return nil }
            for position in kanjiPositions where form[position] != stem[position] {
                form[position] = stem[position]
            }
            let spelling = String(form)
            return match.text == original ? nil : SpellingSuggestion(entry: match.entry, spelling: spelling)
        }
        return Array(suggestions.prefix(limit))
    }

    // Kana spellings one edit away. The spelling is stored as typed.
    nonisolated private func kanaEditSuggestions(_ characters: [Character], limit: Int) throws -> [SpellingSuggestion] {
        guard characters.count >= 3 else { return [] }
        let letters = characters.map { String($0) }
        var patterns: Set<String> = []
        for index in letters.indices {
            var deleted = letters; deleted.remove(at: index); patterns.insert(deleted.joined())
            var replaced = letters; replaced[index] = "?"; patterns.insert(replaced.joined())
            if index + 1 < letters.count {
                var merged = letters; merged.replaceSubrange(index...index + 1, with: ["?"]); patterns.insert(merged.joined())
            }
        }
        for index in 0...letters.count {
            var inserted = letters; inserted.insert("?", at: index); patterns.insert(inserted.joined())
        }
        let original = String(characters)
        let matches = try formsMatching(patterns: patterns.sorted(), table: "kana_forms").filter { $0.text != original }
        // One edit from a short word matches a lot (ミンツ: ヤツ, マツ …), so rank by how much of the
        // start and end is shared (ミント keeps ミン), frequency order breaking ties.
        let ranked = matches.enumerated().sorted { lhs, rhs in
            let left = sharedEnds(Array(lhs.element.text), characters), right = sharedEnds(Array(rhs.element.text), characters)
            return left != right ? left > right : lhs.offset < rhs.offset
        }
        return Array(ranked.prefix(limit).map { SpellingSuggestion(entry: $0.element.entry, spelling: original) })
    }

    // Length of the common prefix plus the common suffix of two spellings.
    nonisolated private func sharedEnds(_ lhs: [Character], _ rhs: [Character]) -> Int {
        let prefix = zip(lhs, rhs).prefix { $0 == $1 }.count
        let suffix = zip(lhs.reversed(), rhs.reversed()).prefix { $0 == $1 }.count
        return min(prefix + suffix, min(lhs.count, rhs.count))
    }

    // Forms in `table` matching any of the GLOB patterns, one per entry, most frequent entry first.
    nonisolated private func formsMatching(patterns: [String], table: String) throws -> [(entry: DictionaryEntry, text: String)] {
        guard patterns.isEmpty == false else { return [] }
        let rows: [(Int64, String)] = try withSerializedDatabaseAccess {
            let conditions = patterns.indices.map { "f.text GLOB ?\($0 + 1)" }.joined(separator: " OR ")
            let sql = """
            SELECT f.entry_id, f.text, MIN(wf.frequency_rank) AS best_rank
            FROM \(table) f
            LEFT JOIN word_frequency wf ON wf.entry_id = f.entry_id
            WHERE \(conditions)
            GROUP BY f.entry_id
            ORDER BY (best_rank IS NULL) ASC, best_rank ASC, f.entry_id ASC
            LIMIT 40
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            for (offset, pattern) in patterns.enumerated() {
                try bindText(pattern, index: Int32(offset + 1), statement: statement)
            }
            return try stepRows(statement: statement) { stmt in
                guard let text = sqlite3_column_text(stmt, 1) else { return nil }
                return (Int64(sqlite3_column_int64(stmt, 0)), String(cString: text))
            }
        }
        return try rows.compactMap { entryID, text in
            try lookupEntry(entryID: entryID).map { (entry: $0, text: text) }
        }
    }
}
