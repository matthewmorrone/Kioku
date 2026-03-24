import Foundation

// Stateless CSV parsing and dictionary-enrichment helpers for the import workflow.
// Supports comma, semicolon, tab, and pipe delimiters with RFC 4180 quoted-field handling.
// Falls back to list mode (one word per line) when no delimiter is detected.
enum CSVImport {

    // Parses raw text into import items using auto-detected delimiter or list mode.
    static func parseItems(from text: String) -> [CSVImportItem] {
        guard let firstLine = firstNonEmptyLine(in: text) else { return [] }
        if let delimiter = autoDelimiter(forFirstLine: firstLine) {
            return parseDelimited(text, delimiter: delimiter)
        }
        return parseListMode(text)
    }

    // Fills missing surface, kana, and meaning by looking up each row in the dictionary.
    // Runs on a background thread via a continuation so the main thread stays responsive.
    static func fillMissing(items: inout [CSVImportItem], dictionaryStore: DictionaryStore?) async {
        guard let dictionaryStore, items.isEmpty == false else { return }

        var copy = items
        let enriched: [CSVImportItem] = await withCheckedContinuation { continuation in
            // DictionaryStore serializes its own SQLite access; safe to call from any thread.
            DispatchQueue.global(qos: .userInitiated).async {
                for idx in copy.indices {
                    enrich(&copy[idx], using: dictionaryStore)
                }
                continuation.resume(returning: copy)
            }
        }
        items = enriched
    }

    // Enriches one item in-place by looking up the best dictionary match for its known fields.
    private static func enrich(_ item: inout CSVImportItem, using dictionaryStore: DictionaryStore) {
        let surface = trim(item.providedSurface ?? item.computedSurface)
        let kana = trim(item.providedKana ?? item.computedKana)
        let meaning = trim(item.providedMeaning ?? item.computedMeaning)

        // Skip enrichment when all three fields are already present.
        guard surface == nil || kana == nil || meaning == nil else { return }

        // Build lookup candidates from existing fields, including the meaning field when it contains Japanese.
        var candidates: [String] = []
        if let s = surface { candidates.append(s) }
        if let k = kana { candidates.append(k) }
        if let m = meaning, containsJapaneseScript(m) || isKanaOnly(m) { candidates.append(m) }
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }

        var hit: DictionaryEntry? = nil
        for candidate in candidates {
            let mode: LookupMode = containsKanji(candidate) ? .kanjiAndKana : .kanaOnly
            if let entry = try? dictionaryStore.lookup(surface: candidate, mode: mode).first {
                hit = entry
                break
            }
        }

        guard let entry = hit else { return }

        if surface == nil {
            let proposed = entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? ""
            if proposed.isEmpty == false { item.computedSurface = proposed }
        }
        if kana == nil, let k = entry.kanaForms.first, k.text.isEmpty == false {
            item.computedKana = k.text
        }
        if meaning == nil {
            let gloss = firstGloss(entry)
            if gloss.isEmpty == false { item.computedMeaning = gloss }
        }
    }

    // MARK: - Parsing

    private static func parseListMode(_ text: String) -> [CSVImportItem] {
        var out: [CSVImportItem] = []
        var lineNo = 0
        for raw in text.components(separatedBy: .newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }

            // Route each line to the appropriate field based on script content.
            if containsKanji(line) {
                out.append(CSVImportItem(lineNumber: lineNo, providedSurface: line, providedKana: nil, providedMeaning: nil, providedNote: nil))
            } else if isKanaOnly(line) {
                out.append(CSVImportItem(lineNumber: lineNo, providedSurface: nil, providedKana: line, providedMeaning: nil, providedNote: nil))
            } else {
                out.append(CSVImportItem(lineNumber: lineNo, providedSurface: nil, providedKana: nil, providedMeaning: line, providedNote: nil))
            }
        }
        return out
    }

    private static func parseDelimited(_ text: String, delimiter: Character) -> [CSVImportItem] {
        var out: [CSVImportItem] = []
        var lineNo = 0
        var headerMap: HeaderMap? = nil

        for raw in text.components(separatedBy: .newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false else { continue }

            let cols = splitCSVLine(line, delimiter: delimiter)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            // Attempt header detection on the first non-empty row only.
            if headerMap == nil {
                if let map = buildHeaderMap(from: cols) {
                    headerMap = map
                    continue
                }
            }

            let item: CSVImportItem
            if let map = headerMap {
                // Header-mapped: extract fields by column index.
                func col(_ idx: Int?) -> String? {
                    guard let idx, cols.indices.contains(idx) else { return nil }
                    return trim(cols[idx])
                }
                item = CSVImportItem(
                    lineNumber: lineNo,
                    providedSurface: col(map.surfaceIndex),
                    providedKana: col(map.kanaIndex),
                    providedMeaning: col(map.meaningIndex),
                    providedNote: col(map.noteIndex)
                )
            } else {
                // No header: classify each cell by its script content.
                let classified = classifyRowCells(cols)
                item = CSVImportItem(
                    lineNumber: lineNo,
                    providedSurface: classified.surface,
                    providedKana: classified.kana,
                    providedMeaning: classified.meaning,
                    providedNote: classified.note
                )
            }

            out.append(item)
        }
        return out
    }

    // MARK: - Delimiter detection

    // Returns the most frequent candidate delimiter in the first non-empty line, or nil for list mode.
    private static func autoDelimiter(forFirstLine line: String) -> Character? {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: (delim: Character, count: Int)? = nil
        for delim in candidates {
            let count = line.filter { $0 == delim }.count
            guard count > 0 else { continue }
            if best == nil || count > best!.count { best = (delim, count) }
        }
        return best?.delim
    }

    // MARK: - Header detection

    private struct HeaderMap {
        var surfaceIndex: Int?
        var kanaIndex: Int?
        var meaningIndex: Int?
        var noteIndex: Int?
    }

    // Recognizes common column name variants for surface, kana, meaning, and note.
    // Requires at least two matching columns to avoid treating data rows as headers.
    private static func buildHeaderMap(from cols: [String]) -> HeaderMap? {
        var map = HeaderMap()
        var hits = 0
        for (idx, raw) in cols.enumerated() {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key.isEmpty == false else { continue }
            if ["surface", "kanji", "word", "term", "vocab"].contains(key) {
                map.surfaceIndex = map.surfaceIndex ?? idx; hits += 1
            } else if ["kana", "reading", "yomi", "pronunciation"].contains(key) {
                map.kanaIndex = map.kanaIndex ?? idx; hits += 1
            } else if ["meaning", "gloss", "definition", "english", "en"].contains(key) {
                map.meaningIndex = map.meaningIndex ?? idx; hits += 1
            } else if ["note", "notes", "memo"].contains(key) {
                map.noteIndex = map.noteIndex ?? idx; hits += 1
            }
        }
        return hits >= 2 ? map : nil
    }

    // MARK: - Row classification

    // Assigns each cell to the most appropriate field using script content heuristics.
    private static func classifyRowCells(_ cols: [String]) -> (surface: String?, kana: String?, meaning: String?, note: String?) {
        let values = cols.compactMap { trim($0) }
        guard values.isEmpty == false else { return (nil, nil, nil, nil) }

        let japaneseSurface = values.first(where: { containsKanji($0) })
            ?? values.first(where: { containsJapaneseScript($0) })

        let kana = values.first(where: { isKanaOnly($0) })
            ?? values.first(where: { containsJapaneseScript($0) && containsKanji($0) == false && looksLikeEnglish($0) == false })

        let meaning = values.first(where: { looksLikeEnglish($0) })
            ?? values.first(where: { containsJapaneseScript($0) == false })

        var used = Set<String>()
        if let s = japaneseSurface { used.insert(s) }
        if let k = kana { used.insert(k) }
        if let m = meaning { used.insert(m) }
        let noteParts = values.filter { used.contains($0) == false }
        let note = noteParts.isEmpty ? nil : noteParts.joined(separator: " ")

        return (japaneseSurface, kana, meaning, note)
    }

    // MARK: - RFC 4180 CSV line splitter

    // Splits one line respecting double-quoted fields and escaped interior quotes ("").
    private static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var out: [String] = []
        out.reserveCapacity(4)
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        // Escaped quote — emit one literal quote and skip both.
                        current.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    current.append(ch)
                    i += 1
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                    i += 1
                } else if ch == delimiter {
                    out.append(current)
                    current = ""
                    i += 1
                } else {
                    current.append(ch)
                    i += 1
                }
            }
        }
        out.append(current)
        return out
    }

    // MARK: - Script classification helpers

    private static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value)
            || (0x4E00...0x9FFF).contains($0.value)
            || (0xF900...0xFAFF).contains($0.value)
        }
    }

    private static func isKanaOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        var sawKana = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            let v = scalar.value
            if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0xFF66...0xFF9F).contains(v) {
                sawKana = true
            } else {
                return false
            }
        }
        return sawKana
    }

    private static func containsJapaneseScript(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            let v = $0.value
            return (0x3040...0x309F).contains(v)
                || (0x30A0...0x30FF).contains(v)
                || (0xFF66...0xFF9F).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xF900...0xFAFF).contains(v)
        }
    }

    private static func looksLikeEnglish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, containsJapaneseScript(trimmed) == false else { return false }
        return trimmed.unicodeScalars.contains {
            (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value)
        }
    }

    // MARK: - Utilities

    private static func firstNonEmptyLine(in text: String) -> String? {
        text.components(separatedBy: .newlines).first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
    }

    static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    // Returns the first English gloss from any sense of the entry.
    static func firstGloss(_ entry: DictionaryEntry) -> String {
        for sense in entry.senses {
            if let gloss = sense.glosses.first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) {
                return gloss.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }
}
