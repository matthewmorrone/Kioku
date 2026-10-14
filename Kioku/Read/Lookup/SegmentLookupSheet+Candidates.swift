import UIKit

// The list of possible words at the top of the lookup sheet: a form like いった is 言う, 行く or 要る
// with the same kana, so the reading arrows can't reach the others. Each row shows the word's
// headword, reading and first meaning. When exactly one of them is read the way the sheet shows the
// segment (its furigana: 様 after の is よう, so 様 よう "appearing"), or only one is a word in common
// use (Lexicon.preferredLookupCandidate: 消して → 消す, not the literary 消する), it is shown straight
// away; otherwise nothing is picked for the user — with no context to decide, the sheet shows the
// possibilities alone (no meaning, blank lemma line, no star or word detail) until one is tapped.
// A tapped pick is then the word the sheet shows and is saved with the segment.
// The list and its order come from Lexicon.lookupCandidates.
extension SegmentLookupSheet {
    // Stores the candidates for the current segment. When the form is several words, the shown word
    // is the user's saved pick if it is still one of them, else the only one with the displayed
    // reading, else the only common one, else nothing.
    func adoptLookupCandidates(_ result: (candidates: [LookupCandidate], chosenEntryID: Int64?)?) {
        let candidates = result?.candidates ?? []
        currentSheetLookupCandidates = candidates
        currentSheetLookupBaseLemmaInfo = currentSheetLemmaInfo
        isLookupCandidateListExpanded = false
        guard candidates.count > 1 else { return }
        if let shown = Lexicon.shownLookupCandidate(
            among: candidates,
            chosenEntryID: result?.chosenEntryID,
            displayedReading: activeReadingOverrideProvider?() ?? currentSheetUniqueReadings.first
        ) {
            applyLookupCandidate(shown)
        } else {
            showNoLookupCandidate()
        }
    }

    // The unpicked state: no word, no lemma line, and no parts row (its parts were the engine's
    // guess, e.g. すむ as 済む).
    func showNoLookupCandidate() {
        currentSheetDictionaryEntry = nil
        currentSheetLemmaInfo = nil
        currentSheetCompoundComponents = []
    }

    // True when the form is several words and none has been picked — the sheet then has no word to
    // save or open, and must not fall back to a guess.
    var isAwaitingLookupCandidatePick: Bool {
        currentSheetLookupCandidates.count > 1 && currentSheetDictionaryEntry == nil
    }

    // The readings the header arrows cycle: with several dictionary words, only the shown word's
    // own readings (none while a pick is awaited); otherwise every reading of the surface.
    var readingsForArrows: [String] {
        guard currentSheetLookupCandidates.count > 1 else { return currentSheetUniqueReadings }
        guard let shownID = currentSheetDictionaryEntry?.entryId else { return [] }
        return currentSheetLookupCandidates.first { $0.entry.entryId == shownID }?.surfaceReadings ?? []
    }

    // Makes `candidate` the word the sheet shows, naming it on the lemma line by its headword, or by
    // its kana when the text wrote the word in kana. Any helper words the engine put on the line
    // stay (… + いく keeps its + いく).
    func applyLookupCandidate(_ candidate: LookupCandidate) {
        currentSheetDictionaryEntry = candidate.entry
        var parts = currentSheetLookupBaseLemmaInfo?.lemma.components(separatedBy: " + ") ?? []
        // Kana text keeps a kana lemma line (すんでいる → すむ + いる, not 住む + いる); the list row
        // already says which すむ it is.
        let name = parts.first.map { ScriptClassifier.containsKanji($0) == false } == true
            ? candidate.reading
            : candidate.headword
        if parts.isEmpty { parts = [name] } else { parts[0] = name }
        currentSheetLemmaInfo = (lemma: parts.joined(separator: " + "), chain: currentSheetLookupBaseLemmaInfo?.chain ?? [])
        // The parts row under the meaning names the same word: its first part was the engine's
        // guess (すむ as 済む "to finish" for 住む + いる).
        if currentSheetCompoundComponents.count > 1 {
            let gloss = candidate.entry.senses.first { $0.glosses.isEmpty == false }?.glosses.prefix(3).joined(separator: "; ")
            currentSheetCompoundComponents[0] = (lemma: name, gloss: gloss)
        }
    }

    // Adds one tappable row per candidate to the top of the middle content, the shown one highlighted.
    // Nothing is added when the form is only one word. With a word shown and the list collapsed,
    // only that word's row appears, tapping it reopening the rest; on the open list, tapping
    // another row picks it and collapses the list, tapping the shown one clears the pick.
    func addLookupCandidateRows(to stack: UIStackView, parent: UIViewController?) {
        let allCandidates = currentSheetLookupCandidates
        guard allCandidates.count > 1 else { return }
        let shownID = currentSheetDictionaryEntry?.entryId
        let isCollapsed = shownID != nil && isLookupCandidateListExpanded == false
        let candidates = isCollapsed ? allCandidates.filter { $0.entry.entryId == shownID } : allCandidates

        // Weak: the rows' tap closures capture refresh(), and the sheet owns the rows.
        weak let sheetVC = parent as? SurfaceSheetViewController
        // Rebuilds the sheet's rows after the list opens, closes or changes pick.
        func refresh() {
            if let sheetVC {
                sheetVC.updateLemmaChain()
                sheetVC.updateMiddleContent()
                sheetVC.updateSaveButtonAppearance()
                sheetVC.updateOpenDetailButtonAppearance()
            }
        }

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

            var rowViews: [UIView] = [headwordLabel, readingLabel, glossLabel]
            // The shown word's row carries its control: open (with how many others) when the list
            // is closed, clear when it's open.
            if shownID != nil, candidate.entry.entryId == shownID {
                let toggle = UILabel()
                toggle.font = .systemFont(ofSize: 12, weight: .semibold)
                toggle.textColor = .secondaryLabel
                toggle.text = isCollapsed ? "+\(allCandidates.count - 1) ⌄" : "✕"
                toggle.setContentHuggingPriority(.required, for: .horizontal)
                toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
                rowViews.append(toggle)
            }
            let row = UIStackView(arrangedSubviews: rowViews)
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            row.layer.cornerRadius = 8
            row.backgroundColor = candidate.entry.entryId == shownID ? .tertiarySystemFill : .clear
            row.isUserInteractionEnabled = true
            row.accessibilityTraits = candidate.entry.entryId == shownID ? [.button, .selected] : .button
            row.addGestureRecognizer(ClosureTapGesture { [weak self] in
                guard let self else { return }
                // The shown word's row opens the closed list; on the open list it clears the pick,
                // back to no word chosen. Not saved: the next lookup chooses as usual.
                if candidate.entry.entryId == shownID {
                    if self.isLookupCandidateListExpanded {
                        self.showNoLookupCandidate()
                        sheetVC?.updateReadingFurigana()
                    } else {
                        self.isLookupCandidateListExpanded = true
                    }
                    refresh()
                    return
                }
                self.applyLookupCandidate(candidate)
                self.onLookupCandidateChosen?(candidate.entry.entryId)
                self.isLookupCandidateListExpanded = false
                sheetVC?.adoptReadingsOfPickedCandidate()
                refresh()
            })
            list.addArrangedSubview(row)
        }
        stack.addArrangedSubview(list)
    }
}
