import UIKit

// The list of possible words at the top of the lookup sheet. The header arrows step through every
// reading of the form, and a reading usually names the word (抱く だく / いだく / うだく; 怒り おこり →
// 怒る); the list is for what a reading leaves undecided — words that share it (いった → 言う, 行く
// or 要る; 怒り いかり → the noun 怒り or 怒る いかる). Each row shows the word's headword, reading and
// first meaning. The word shown is the user's pick when it shares the reading, else the only word
// that does, else the only common one (Lexicon.preferredLookupCandidate: 消して → 消す, not the
// literary 消する); otherwise nothing is picked for the user — the sheet shows the possibilities
// alone (no meaning, blank lemma line, no star or word detail) until one is tapped. A tapped pick is
// then the word the sheet shows and is saved with the segment. The candidates come from
// Lexicon.lookupCandidates.
extension SegmentLookupSheet {
    // Stores the candidates for the current segment and shows the word its displayed reading names
    // (see the file comment), or nothing when that reading leaves it undecided.
    func adoptLookupCandidates(_ result: (candidates: [LookupCandidate], chosenEntryID: Int64?)?) {
        let candidates = result?.candidates ?? []
        currentSheetLookupCandidates = candidates
        currentSheetLookupBaseLemmaInfo = currentSheetLemmaInfo
        currentSheetChosenEntryID = result?.chosenEntryID
        currentSheetDisplayedReading = activeReadingOverrideProvider?() ?? currentSheetUniqueReadings.first
        isLookupCandidateListExpanded = false
        guard candidates.count > 1,
              Lexicon.lookupCandidates(candidates, sharingReading: currentSheetDisplayedReading).isEmpty == false
        else { return }
        showLookupCandidate(forReading: currentSheetDisplayedReading)
    }

    // An arrow moved the header to `reading`: shows the word that reading names, or the list of
    // words sharing it. False when the form is only one word or no listed word is read that way,
    // leaving the caller's reading→entry map to follow the reading.
    func followDisplayedReading(_ reading: String) -> Bool {
        currentSheetDisplayedReading = reading
        guard currentSheetLookupCandidates.count > 1,
              Lexicon.lookupCandidates(currentSheetLookupCandidates, sharingReading: reading).isEmpty == false
        else { return false }
        isLookupCandidateListExpanded = false
        showLookupCandidate(forReading: reading)
        return true
    }

    // Shows the word Lexicon.shownLookupCandidate picks for `reading`, or the unpicked state.
    private func showLookupCandidate(forReading reading: String?) {
        if let shown = Lexicon.shownLookupCandidate(
            among: currentSheetLookupCandidates,
            chosenEntryID: currentSheetChosenEntryID,
            displayedReading: reading
        ) {
            applyLookupCandidate(shown)
        } else {
            showNoLookupCandidate()
        }
    }

    // The words the list offers: those sharing the displayed reading, when there are several.
    var visibleLookupCandidates: [LookupCandidate] {
        guard currentSheetLookupCandidates.count > 1 else { return [] }
        let sharing = Lexicon.lookupCandidates(currentSheetLookupCandidates, sharingReading: currentSheetDisplayedReading)
        return sharing.count > 1 ? sharing : []
    }

    // The unpicked state: no word, no lemma line, and no parts row (its parts were the engine's
    // guess, e.g. すむ as 済む).
    func showNoLookupCandidate() {
        currentSheetDictionaryEntry = nil
        currentSheetLemmaInfo = nil
        currentSheetCompoundComponents = []
    }

    // True when the displayed reading leaves several words and none has been picked — the sheet then
    // has no word to save or open, and must not fall back to a guess.
    var isAwaitingLookupCandidatePick: Bool {
        visibleLookupCandidates.count > 1 && currentSheetDictionaryEntry == nil
    }

    // The readings the header arrows cycle: every reading of the surface plus every word's own
    // (抱く だく / いだく / うだく), in that order without repeats.
    var readingsForArrows: [String] {
        // A kana form of one of the words that DictionaryEntry.offeredReadings leaves out (search-only,
        // katakana copy, archaic unless enabled) is left out here too, as on the word detail page; the
        // reading on screen always stays.
        let entries = currentSheetLookupCandidates.map(\.entry) + [currentSheetDictionaryEntry].compactMap { $0 }
        let keeping = Set([currentSheetDisplayedReading].compactMap { $0 })
        let offered = Set(entries.flatMap { $0.offeredReadings(includeArchaic: DictionarySettings.includeArchaicReadings, keeping: keeping) })
        let spelled = Set(entries.flatMap { $0.kanaForms.map(\.text) })
        var readings: [String] = []
        for reading in currentSheetUniqueReadings + currentSheetLookupCandidates.flatMap(\.surfaceReadings)
        where readings.contains(reading) == false && (spelled.contains(reading) == false || offered.contains(reading) || keeping.contains(reading)) {
            readings.append(reading)
        }
        return readings
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

    // Adds one tappable row per word sharing the displayed reading to the top of the middle content,
    // the shown one highlighted. Nothing is added when the reading names a single word. With a word shown and the list collapsed,
    // only that word's row appears, tapping it reopening the rest; on the open list, tapping
    // another row picks it and collapses the list, tapping the shown one clears the pick.
    func addLookupCandidateRows(to stack: UIStackView, parent: UIViewController?) {
        let allCandidates = visibleLookupCandidates
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
            readingLabel.textColor = .label
            readingLabel.setContentHuggingPriority(.required, for: .horizontal)
            readingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            let glossLabel = UILabel()
            glossLabel.text = candidate.entry.senses.first?.glosses.first ?? ""
            glossLabel.font = .systemFont(ofSize: 14)
            glossLabel.textColor = .label
            glossLabel.numberOfLines = 1
            glossLabel.lineBreakMode = .byTruncatingTail

            var rowViews: [UIView] = [headwordLabel, readingLabel, glossLabel]
            // The shown word's row carries its control: open (with how many others) when the list
            // is closed, clear when it's open.
            if shownID != nil, candidate.entry.entryId == shownID {
                let toggle = UILabel()
                toggle.font = .systemFont(ofSize: 12, weight: .semibold)
                toggle.textColor = .label
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
                self.currentSheetChosenEntryID = candidate.entry.entryId
                self.onLookupCandidateChosen?(candidate.entry.entryId)
                self.isLookupCandidateListExpanded = false
                refresh()
            })
            list.addArrangedSubview(row)
        }
        stack.addArrangedSubview(list)
    }
}
