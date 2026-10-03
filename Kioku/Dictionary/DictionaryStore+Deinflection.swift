import Foundation
import SQLite3

// The deinflection rules, generated into the dictionary from UniDic, the grammar table and the
// hand-added exceptions (Resources/generate_db.py, import_deinflection_rules).
extension DictionaryStore {
    // Reads deinflection_rules and deinflection_lists into the rule set the Deinflector is built from.
    // Rules come back in id order, which keeps each group in the order the generator wrote it.
    nonisolated func fetchDeinflectionRuleSet() throws -> DeinflectionRuleSet {
        try withSerializedDatabaseAccess {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                sql: "SELECT rule_group, kana_in, kana_out, rules_in, rules_out, helper FROM deinflection_rules ORDER BY id",
                statement: &statement
            )
            let rows = try stepRows(statement: statement) { stmt -> (String, DeinflectionRule)? in
                guard let group = columnText(stmt, 0), let kanaIn = columnText(stmt, 1),
                      let kanaOut = columnText(stmt, 2), let rulesIn = columnText(stmt, 3),
                      let rulesOut = columnText(stmt, 4) else { return nil }
                let rule = DeinflectionRule(
                    kanaIn: kanaIn,
                    kanaOut: kanaOut,
                    rulesIn: rulesIn.split(separator: ",").map(String.init),
                    rulesOut: rulesOut.split(separator: ",").map(String.init),
                    helper: columnText(stmt, 5)
                )
                return (group, rule)
            }
            var groupedRules: [String: [DeinflectionRule]] = [:]
            for (group, rule) in rows {
                groupedRules[group, default: []].append(rule)
            }

            var listStatement: OpaquePointer?
            defer { sqlite3_finalize(listStatement) }
            try prepare(sql: "SELECT list, value FROM deinflection_lists", statement: &listStatement)
            let lists = try stepRows(statement: listStatement) { stmt -> (String, String)? in
                guard let list = columnText(stmt, 0), let value = columnText(stmt, 1) else { return nil }
                return (list, value)
            }
            return DeinflectionRuleSet(
                groupedRules: groupedRules,
                nonIchidanRuVerbs: Set(lists.filter { $0.0 == "nonIchidanRuVerbs" }.map(\.1)),
                intermediateForms: Set(lists.filter { $0.0 == "intermediateForms" }.map(\.1))
            )
        }
    }

    // A text column as a String, nil when SQL NULL.
    private nonisolated func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
}
