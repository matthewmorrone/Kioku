import UIKit

// The list of possible words at the top of the lookup sheet: a form like いった is 言う, 行く or 要る
// with the same kana, so the reading arrows can't reach the others. Each row shows the word's
// headword, reading and first meaning. Nothing is picked for the user — with no context to decide,
// the sheet shows the possibilities alone (no meaning, blank lemma line, no star or word detail)
// until one is tapped; the pick is then the word the sheet shows and is saved with the segment.
// The list and its order come from Lexicon.lookupCandidates.
extension SegmentLookupSheet {
    // Stores the candidates for the current segment. When the form is several words, the shown word
    // is the user's saved pick if it is still one of them, and otherwise nothing.
    func adoptLookupCandidates(_ result: (candidates: [LookupCandidate], chosenEntryID: Int64?)?) {
        let candidates = result?.candidates ?? []
        currentSheetLookupCandidates = candidates
        currentSheetLookupBaseLemmaInfo = currentSheetLemmaInfo
        guard candidates.count > 1 else { return }
        if let chosen = candidates.first(where: { $0.entry.entryId == result?.chosenEntryID }) {
            applyLookupCandidate(chosen)
        } else {
            currentSheetDictionaryEntry = nil
            currentSheetLemmaInfo = nil
        }
    }

    // True when the form is several words and none has been picked — the sheet then has no word to
    // save or open, and must not fall back to a guess.
    var isAwaitingLookupCandidatePick: Bool {
        currentSheetLookupCandidates.count > 1 && currentSheetDictionaryEntry == nil
    }

    // Makes `candidate` the word the sheet shows, naming it by its headword on the lemma line. Any
    // helper words the engine put on the line stay (… + いく keeps its + いく).
    func applyLookupCandidate(_ candidate: LookupCandidate) {
        currentSheetDictionaryEntry = candidate.entry
        var parts = currentSheetLookupBaseLemmaInfo?.lemma.components(separatedBy: " + ") ?? []
        if parts.isEmpty { parts = [candidate.headword] } else { parts[0] = candidate.headword }
        currentSheetLemmaInfo = (lemma: parts.joined(separator: " + "), chain: currentSheetLookupBaseLemmaInfo?.chain ?? [])
    }

    // Adds one tappable row per candidate to the top of the middle content, the shown one highlighted.
    // Nothing is added when the form is only one word.
    func addLookupCandidateRows(to stack: UIStackView, parent: UIViewController?) {
        let candidates = currentSheetLookupCandidates
        guard candidates.count > 1 else { return }
        let shownID = currentSheetDictionaryEntry?.entryId

        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 2
        list.alignment = .fill
        for candidate in candidates {
            let headwordLabel = UILabel()
            headwordLabel.text = candidate.headword
            headwordLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            headwordLabel.textColor = .label
            headwordLabel.setContentHuggingPriority(.required, for: .horizontal)
            headwordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            let readingLabel = UILabel()
            readingLabel.text = candidate.reading == candidate.headword ? "" : candidate.reading
            readingLabel.font = .systemFont(ofSize: 12)
            readingLabel.textColor = .secondaryLabel
            readingLabel.setContentHuggingPriority(.required, for: .horizontal)
            readingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            let glossLabel = UILabel()
            glossLabel.text = candidate.entry.senses.first?.glosses.first ?? ""
            glossLabel.font = .systemFont(ofSize: 14)
            glossLabel.textColor = .secondaryLabel
            glossLabel.numberOfLines = 1
            glossLabel.lineBreakMode = .byTruncatingTail

            let row = UIStackView(arrangedSubviews: [headwordLabel, readingLabel, glossLabel])
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            row.layer.cornerRadius = 8
            row.backgroundColor = candidate.entry.entryId == shownID ? .tertiarySystemFill : .clear
            row.isUserInteractionEnabled = true
            row.accessibilityTraits = candidate.entry.entryId == shownID ? [.button, .selected] : .button
            row.addGestureRecognizer(ClosureTapGesture { [weak self, weak parent] in
                guard let self else { return }
                self.applyLookupCandidate(candidate)
                self.onLookupCandidateChosen?(candidate.entry.entryId)
                if let sheetVC = parent as? SurfaceSheetViewController {
                    sheetVC.updateLemmaChain()
                    sheetVC.updateMiddleContent()
                    sheetVC.updateSaveButtonAppearance()
                    sheetVC.updateOpenDetailButtonAppearance()
                }
            })
            list.addArrangedSubview(row)
        }
        stack.addArrangedSubview(list)
    }
}
