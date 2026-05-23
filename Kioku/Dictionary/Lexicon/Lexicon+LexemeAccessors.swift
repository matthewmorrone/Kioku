import Foundation

// Lexeme-by-ID accessors for Lexicon: resolves a stored lexeme record into its
// orthographic forms, senses, readings, and headword display fields, plus the
// script-classification convenience wrappers used by lexeme rendering callers.
extension Lexicon {
    // Returns one core lexeme record by stable ID string.
    public func lexeme(_ id: String) -> DictionaryEntry? {
        guard let entryID = entryID(from: id) else {
            return nil
        }

        guard let dictionaryStore else {
            return nil
        }

        do {
            return try dictionaryStore.lookupEntry(entryID: entryID)
        } catch {
            print("lexeme lookup failed for id \(id): \(error)")
            return nil
        }
    }

    // Returns all displayable orthographic forms for one lexeme.
    public func forms(_ lexemeId: String) -> [(spelling: String, reading: String)] {
        guard let entry = lexeme(lexemeId) else {
            return []
        }

        let fallbackReading = entry.kanaForms.first?.text ?? ""
        var builtForms: [(spelling: String, reading: String)] = []

        for kanjiForm in entry.kanjiForms {
            builtForms.append((spelling: kanjiForm.text, reading: fallbackReading))
        }

        for kanaForm in entry.kanaForms {
            builtForms.append((spelling: kanaForm.text, reading: kanaForm.text))
        }

        return uniqueForms(builtForms)
    }

    // Returns flattened gloss strings for one lexeme in persisted sense order.
    public func senses(_ lexemeId: String) -> [String] {
        guard let entry = lexeme(lexemeId) else {
            return []
        }

        var orderedGlosses: [String] = []
        for sense in entry.senses {
            for gloss in sense.glosses {
                let trimmedGloss = gloss.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedGloss.isEmpty == false {
                    orderedGlosses.append(trimmedGloss)
                }
            }
        }

        return orderedGlosses
    }

    // Returns primary reading for one lexeme using first kana form ordering.
    public func primaryReading(_ lexemeId: String) -> String? {
        guard let entry = lexeme(lexemeId) else {
            return nil
        }

        return entry.kanaForms.first?.text
    }

    // Returns preferred headword display form for one lexeme.
    public func displayForm(_ lexemeId: String) -> (spelling: String, reading: String)? {
        let allForms = forms(lexemeId)
        guard allForms.isEmpty == false else {
            return nil
        }

        for form in allForms where ScriptClassifier.containsKanji(form.spelling) {
            return form
        }

        return allForms.first
    }

    // Returns the lexeme form that best matches one tapped surface.
    // Inlines the displayForm fallback to reuse the already-fetched form list and avoid a second DB lookup.
    public func matchedForm(surface: String, lexemeId: String) -> (spelling: String, reading: String)? {
        let allForms = forms(lexemeId)

        if let exactMatch = allForms.first(where: { $0.spelling == surface }) {
            return exactMatch
        }

        let lemmaCandidates = lemma(surface: surface)
        if let lemmaMatch = allForms.first(where: { lemmaCandidates.contains($0.spelling) }) {
            return lemmaMatch
        }

        // Inline displayForm preference so we don't re-fetch the entry.
        for form in allForms where ScriptClassifier.containsKanji(form.spelling) {
            return form
        }

        return allForms.first
    }

    // Returns whether one text contains any kanji scalar.
    public func containsKanji(_ text: String) -> Bool {
        ScriptClassifier.containsKanji(text)
    }

    // Returns whether one text is entirely kana.
    public func isKana(_ text: String) -> Bool {
        ScriptClassifier.isPureKana(text)
    }

    // Returns unique kanji characters present in all lexeme forms.
    public func kanjiCharacters(_ lexemeId: String) -> [String] {
        let allForms = forms(lexemeId)
        var seenCharacters = Set<String>()
        var orderedCharacters: [String] = []

        for form in allForms {
            for character in form.spelling {
                let characterString = String(character)
                if ScriptClassifier.containsKanji(characterString),
                   seenCharacters.contains(characterString) == false {
                    seenCharacters.insert(characterString)
                    orderedCharacters.append(characterString)
                }
            }
        }

        return orderedCharacters
    }

    // Parses stable lexeme ID text to numeric dictionary entry ID.
    private func entryID(from id: String) -> Int64? {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawID = Int64(trimmedID) {
            return rawID
        }

        guard trimmedID.hasPrefix("lex_") else {
            return nil
        }

        let numericPart = String(trimmedID.dropFirst(4))
        return Int64(numericPart)
    }

    // Removes duplicate forms while preserving first-seen ordering semantics.
    private func uniqueForms(_ forms: [(spelling: String, reading: String)]) -> [(spelling: String, reading: String)] {
        var seen = Set<String>()
        var unique: [(spelling: String, reading: String)] = []

        for form in forms {
            let key = "\(form.spelling)|\(form.reading)"
            if seen.contains(key) {
                continue
            }

            seen.insert(key)
            unique.append(form)
        }

        return unique
    }
}
