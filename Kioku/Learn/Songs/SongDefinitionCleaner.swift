import Foundation

// Reduces a breakdown word's definition to its gloss. The model's manufactured-interpretation
// commentary (SongBreakdownPrompt rule 5 — "carries the sense of…", "Echoes line 1…", "The
// potential form here implies…") keeps arriving after the gloss even though the prompt forbids
// it, and a mechanical cut is more reliable than another prompt instruction. It lands after a
// semicolon, after the gloss's first sentence, or after a spaced em dash, so the definition is
// cut at whichever of those comes first. Double quotes around glosses ("to swim") are dropped
// too: on screen they're noise, and read aloud they're nothing. Applied to both the displayed
// definition (SongLineCard) and the narrated one (SongListenScript) so what's spoken always
// matches what's shown.
nonisolated enum SongDefinitionCleaner {
    // Words whose trailing period is an abbreviation, not the end of the gloss's sentence.
    private static let abbreviations: Set<String> = ["e.g", "i.e", "lit", "cf", "vs", "etc", "approx", "esp"]

    // The gloss: inline markdown and double quotes stripped, a leading "= line N." / "as in line
    // N," back-reference dropped, cut at the first commentary boundary, and any comma or period
    // the cut left dangling trimmed. Quotes go first so a sentence ending inside one (`…run." The
    // heart…`) still reads as a sentence end.
    static func clean(_ raw: String) -> String {
        var text = SongLineCard.stripInlineMarkdown(raw)
        text = text.replacingOccurrences(of: #"["“”]"#, with: "", options: .regularExpression)
        // A definition that is nothing but the back-reference keeps it — "as in line 8" says more
        // than an empty row.
        let withoutBackReference = text.replacingOccurrences(
            of: #"^\s*(?:=\s*line\s*\d+\.?|as in line\s*\d+,?)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        if withoutBackReference.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",."))).isEmpty == false {
            text = withoutBackReference
        }
        if let cut = firstCommentaryBoundary(in: text) {
            text = String(text[..<cut])
        }
        return text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.")))
    }

    // Where the gloss ends: the first semicolon, spaced em dash, or sentence end (a period or 。
    // followed by more text), whichever comes first. A period ending an abbreviation ("e.g.")
    // doesn't count. Nil when the definition is a single clause.
    private static func firstCommentaryBoundary(in text: String) -> String.Index? {
        var candidates: [String.Index] = []
        if let semicolon = text.firstIndex(of: ";") { candidates.append(semicolon) }
        if let dash = text.range(of: " — ") { candidates.append(dash.lowerBound) }
        if let fullStop = text.range(of: #"。\s*\S"#, options: .regularExpression) {
            candidates.append(fullStop.lowerBound)
        }
        var searchStart = text.startIndex
        while let period = text.range(of: #"\.\s+\S"#, options: .regularExpression, range: searchStart..<text.endIndex) {
            let precedingWord = text[..<period.lowerBound].split(whereSeparator: { $0 == " " || $0 == "(" }).last.map(String.init) ?? ""
            if abbreviations.contains(precedingWord.lowercased()) {
                searchStart = period.upperBound
                continue
            }
            candidates.append(period.lowerBound)
            break
        }
        return candidates.min()
    }
}
