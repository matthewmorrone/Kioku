import UIKit

extension SegmentLookupSheet {
    // Adds the whole-form meaning of an inflected or helper-word form (起こりそう, 言いたくない) above
    // the lemma's senses: the guess once known, a spinner while CompositeGlossGuesser works on it,
    // nothing for a word in its dictionary form or when no guess can be made. Starts the request the
    // first time a surface and lemma line show up here and re-renders the sheet when it lands.
    func addCompositeGloss(
        for surface: String,
        primarySense: DictionaryEntrySense,
        to middleContentStack: UIStackView,
        parent: UIViewController?
    ) {
        // A word the dictionary defines as a whole (思い出す) needs no guess.
        guard let info = currentSheetLemmaInfo, info.lemma != surface,
              currentSheetDictionaryEntryDefines(surface) == false else { return }
        let key = surface + "\u{1F}" + info.lemma
        let isNewKey = compositeGlossKey != key
        if isNewKey {
            compositeGlossKey = key
            compositeGlossTask?.cancel()
            compositeGlossTask = nil
            // A stored answer shows at once, without a spinner flashing up first.
            // Asked once per key: a failed guess leaves nothing and is not retried on re-render.
            compositeGloss = GuessedGlossStore.composite.gloss(for: surface, in: info.lemma)
        }
        if compositeGloss == nil, compositeGlossTask == nil, compositeGlossKey == key, isNewKey {
            let formDescription = InflectionFormNames.describe(info.chain)
            let baseGloss = primarySense.glosses.prefix(2).joined(separator: "; ")
            compositeGlossTask = Task { @MainActor [weak self, weak parent] in
                let gloss = await CompositeGlossGuesser.guess(
                    surface: surface,
                    lemmaLine: info.lemma,
                    formDescription: formDescription.isEmpty ? nil : formDescription,
                    baseGloss: baseGloss.isEmpty ? nil : baseGloss
                )
                guard let self, Task.isCancelled == false, self.compositeGlossKey == key else { return }
                self.compositeGloss = gloss
                self.compositeGlossTask = nil
                (parent as? SurfaceSheetViewController)?.updateMiddleContent()
            }
        }
        if let compositeGloss {
            middleContentStack.addArrangedSubview(makeGuessedGlossRow(
                compositeGloss,
                explanation: CompositeGlossGuesser.explanation(surface: surface, lemmaLine: info.lemma),
                parent: parent
            ))
        } else if compositeGlossTask != nil {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            middleContentStack.addArrangedSubview(spinner)
        }
    }

    // True when the shown entry has `surface` among its own spellings, so its senses already define
    // the whole form rather than one of its parts.
    func currentSheetDictionaryEntryDefines(_ surface: String) -> Bool {
        guard let entry = currentSheetDictionaryEntry else { return false }
        return entry.kanjiForms.contains { $0.text == surface } || entry.kanaForms.contains { $0.text == surface }
    }
}
