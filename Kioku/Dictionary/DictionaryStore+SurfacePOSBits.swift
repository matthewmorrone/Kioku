import Foundation
import SQLite3

// Builds the surface → packed POS-bits map that lets Lexicon's deinflection pruning run
// without touching SQLite. Single startup query — UNION over (kanji, senses) and
// (kana_forms, senses), grouped by surface — Swift-side OR-reduces each row's pos string
// into the compact bit representation defined by PartOfSpeech.bits.
extension DictionaryStore {
    // Appends ",on-mim" to a sense's pos string when its misc field carries the on-mim tag —
    // generate_db.py stores on-mim in `misc`, not `pos`, but POS-bit consumers need it folded
    // into the pos string they parse. Shared by this file's per-form UNION ALL legs and
    // fetchPartOfSpeechByEntryID's per-entry GROUP_CONCAT (DictionaryStore+SurfaceData.swift).
    nonisolated static let posWithOnMimCaseSQL = "CASE WHEN ',' || COALESCE(misc, '') || ',' LIKE '%,on-mim,%' THEN ',on-mim' ELSE '' END"

    // Runs a single SQL query that emits one (surface, raw_pos) row per (form, sense)
    // pair, then reduces them in Swift into surface → UInt64 bits. The ~580k rows carry only a
    // few hundred distinct pos strings, so each is parsed once (bitsByRawPOS) rather than per row.
    nonisolated func fetchSurfacePOSBitsMap() throws -> [String: UInt64] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT surface, pos FROM (
                SELECT k.text AS surface, s.pos || \(Self.posWithOnMimCaseSQL) AS pos
                FROM kanji k
                JOIN senses s ON s.entry_id = k.entry_id
                UNION ALL
                SELECT n.text AS surface, s.pos || \(Self.posWithOnMimCaseSQL) AS pos
                FROM kana_forms n
                JOIN senses s ON s.entry_id = n.entry_id
            )
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)

            var map: [String: UInt64] = [:]
            map.reserveCapacity(500_000)
            var bitsByRawPOS: [String: UInt64] = [:]

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                guard let surfacePtr = sqlite3_column_text(statement, 0) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }
                let surface = String(cString: surfacePtr)
                let posPtr = sqlite3_column_text(statement, 1)
                let raw = posPtr.map { String(cString: $0) } ?? ""
                let bits: UInt64
                if let known = bitsByRawPOS[raw] {
                    bits = known
                } else {
                    bits = PartOfSpeech.bits(from: raw)
                    bitsByRawPOS[raw] = bits
                }
                if bits != 0 {
                    map[surface, default: 0] |= bits
                }
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage()).logged()
            }

            return map
        }
    }

    // Populates the in-memory POS bits map. Must be called once at app start before the
    // store is published to the UI, same lifecycle constraint as populateCanonicalEntryIDMap.
    nonisolated func populateSurfacePOSBitsMap() throws {
        surfacePOSBitsMap = try fetchSurfacePOSBitsMap()
    }

    // Hashtable lookup of POS bits for a surface. Returns 0 when the surface isn't in
    // the dictionary — callers treat zero as "no POS info" exactly the same way the old
    // SQL-backed posBits behaved.
    public nonisolated func posBits(forSurface surface: String) -> UInt64 {
        SpellingNormalizer.firstHit(for: surface) { surfacePOSBitsMap[$0] } ?? 0
    }
}
