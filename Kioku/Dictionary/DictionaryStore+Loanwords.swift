import Foundation
import SQLite3

// Dictionary queries behind the Read tab's English → katakana conversion (EnglishKatakanaConverter):
// the katakana loanwords glossed with an English word, and whether a word is English at all.
extension DictionaryStore {
    // Katakana-only forms of kanji-less entries with a gloss that IS `english` once parentheticals,
    // a leading "to " and hyphens are set aside ("make-up" matches "make up"). Words under three
    // letters are matched exactly by a scan, because the trigram index can't hold them.
    nonisolated func loanwordCandidates(for english: String) -> [LoanwordCandidate] {
        let term = english.lowercased()
        guard term.isEmpty == false else { return [] }
        let usesIndex = term.count >= 3
        let sql = usesIndex ? """
            SELECT k.text, COALESCE(k.wordfreq_zipf, 0), g.gloss
            FROM glosses_fts f JOIN glosses g ON g.id = f.rowid JOIN senses s ON s.id = g.sense_id
            JOIN kana_forms k ON k.entry_id = s.entry_id
            WHERE glosses_fts MATCH ?1 AND NOT EXISTS (SELECT 1 FROM kanji j WHERE j.entry_id = s.entry_id)
            """ : """
            SELECT k.text, COALESCE(k.wordfreq_zipf, 0), g.gloss
            FROM glosses g JOIN senses s ON s.id = g.sense_id JOIN kana_forms k ON k.entry_id = s.entry_id
            WHERE g.gloss = ?1 COLLATE NOCASE AND NOT EXISTS (SELECT 1 FROM kanji j WHERE j.entry_id = s.entry_id)
            """
        let squashed = term.replacingOccurrences(of: " ", with: "")
        do {
            return try withSerializedDatabaseAccess {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare(sql: sql, statement: &statement)
                try bindText(usesIndex ? "\"" + term.replacingOccurrences(of: "\"", with: "") + "\"" : term, index: 1, statement: statement)
                return try stepRows(statement: statement) { stmt in
                    guard let kanaText = sqlite3_column_text(stmt, 0), let glossText = sqlite3_column_text(stmt, 2) else { return nil }
                    let kana = String(cString: kanaText)
                    let gloss = Self.normalizedGloss(String(cString: glossText))
                    guard Self.isKatakana(kana), gloss == term || gloss.replacingOccurrences(of: " ", with: "") == squashed else { return nil }
                    return LoanwordCandidate(kana: kana, frequency: sqlite3_column_double(stmt, 1))
                }
            }
        } catch {
            print("[DictionaryStore] loanword lookup failed for \(term): \(error)")
            return []
        }
    }

    // Whether `word` appears as a whole word in any English gloss — true for English, false for
    // romanized Japanese like "kioku". Words under three letters count as English.
    nonisolated func appearsInEnglishGloss(_ word: String) -> Bool {
        let term = word.lowercased()
        guard term.count >= 3 else { return true }
        guard let boundary = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b", options: .caseInsensitive) else { return true }
        do {
            return try withSerializedDatabaseAccess {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare(sql: "SELECT gloss FROM glosses_fts WHERE glosses_fts MATCH ?1 LIMIT 200", statement: &statement)
                try bindText("\"" + term.replacingOccurrences(of: "\"", with: "") + "\"", index: 1, statement: statement)
                let glosses = try stepRows(statement: statement) { stmt in
                    sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                }
                return glosses.contains { boundary.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
            }
        } catch {
            print("[DictionaryStore] English-gloss check failed for \(term): \(error)")
            return true
        }
    }

    // A gloss reduced to the words it glosses: "make-up (cosmetics)" → "make up" — parentheticals
    // removed, lowercased, hyphens as spaces, and a verb's leading "to " dropped.
    nonisolated private static func normalizedGloss(_ gloss: String) -> String {
        var s = gloss.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .lowercased().trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("to ") { s = String(s.dropFirst(3)) }
        return s.replacingOccurrences(of: "-", with: " ")
    }

    // True when every scalar is in the katakana block (ー included).
    nonisolated private static func isKatakana(_ s: String) -> Bool {
        s.isEmpty == false && s.unicodeScalars.allSatisfy { (0x30A0...0x30FF).contains($0.value) }
    }
}
