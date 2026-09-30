import UIKit

// Caps for the compact meanings list in the lookup sheet. Three senses covers the dominant
// meanings of nearly all words without growing the sheet detent; highly polysemous entries
// collapse the tail into a "+N more" hint and full detail stays in the word-detail screen.
private let maxVisibleSheetSenses = 3
// Glosses within one sense are near-synonyms, so the first few carry the meaning.
private let maxGlossesPerSheetSense = 3

extension SegmentLookupSheet {
    // Builds one compact sense line: optional number, glosses (capped), and a dim part-of-speech
    // suffix. The primary sense renders at full size/color; later senses are smaller and dimmer
    // so the most common meaning stays visually dominant.
    func makeSheetSenseLabel(
        _ sense: DictionaryEntrySense,
        number: Int?,
        isPrimary: Bool,
        showsPos: Bool,
        maxLayoutWidth: CGFloat
    ) -> UILabel {
        let glossFont = UIFont.systemFont(ofSize: isPrimary ? 15 : 13)
        let glossColor: UIColor = isPrimary ? .label : .secondaryLabel
        let detailFont = UIFont.systemFont(ofSize: isPrimary ? 12 : 11)

        let line = NSMutableAttributedString()
        if let number {
            line.append(NSAttributedString(
                string: "\(number). ",
                attributes: [.font: glossFont, .foregroundColor: UIColor.tertiaryLabel]
            ))
        }

        var glossText = sense.glosses.prefix(maxGlossesPerSheetSense).joined(separator: "; ")
        if sense.glosses.count > maxGlossesPerSheetSense {
            glossText += "; …"
        }
        line.append(NSAttributedString(
            string: glossText,
            attributes: [.font: glossFont, .foregroundColor: glossColor]
        ))

        if showsPos, let pos = sense.pos, pos.isEmpty == false {
            line.append(NSAttributedString(
                string: "  ·  \(JMdictTagExpander.expandAll(pos))",
                attributes: [.font: detailFont, .foregroundColor: UIColor.tertiaryLabel]
            ))
        }

        let label = UILabel()
        label.attributedText = line
        label.numberOfLines = 0
        label.textAlignment = .natural
        label.preferredMaxLayoutWidth = maxLayoutWidth
        return label
    }

    // Multi-line UILabels need preferredMaxLayoutWidth set before the first systemLayoutSizeFitting
    // pass so the detent resolver gets the wrapped height instead of single-line height. Without it,
    // the sheet detent renders at single-line height and the wrapped definition is clipped. The
    // lookup sheet is full-width; subtract container/stack padding to land on the label's actual
    // rendered width.
    func sheetContentWidth() -> CGFloat {
        max(200, activeScreenBounds().width) - (16 * 2) - (6 * 2)
    }

    // Fills the empty middle for a surface with no dictionary entry: the guessed gloss once known,
    // a spinner while it's being fetched, nothing when no guess could be made. Starts the fetch the
    // first time a surface shows up here and re-renders the sheet when it lands.
    private func showGuessedGloss(
        for surface: String,
        in middleContentStack: UIStackView,
        parent: UIViewController?,
        provider: @escaping @MainActor (String) async -> String?
    ) {
        if guessedGlossSurface != surface {
            guessedGlossSurface = surface
            guessedGloss = nil
            glossGuessTask?.cancel()
            glossGuessTask = Task { @MainActor [weak self, weak parent] in
                let gloss = await provider(surface)
                guard let self, Task.isCancelled == false, self.guessedGlossSurface == surface else { return }
                self.guessedGloss = gloss
                self.glossGuessTask = nil
                (parent as? SurfaceSheetViewController)?.updateMiddleContent()
            }
        }
        if let guessedGloss {
            middleContentStack.addArrangedSubview(makeGuessedGlossLabel(guessedGloss))
        } else if glossGuessTask != nil {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            middleContentStack.addArrangedSubview(spinner)
        } else {
            middleContentStack.superview?.isHidden = true
            return
        }
        middleContentStack.superview?.isHidden = false
    }

    // A guessed gloss, styled like a primary sense with a "guess" tag where a sense shows its part
    // of speech.
    private func makeGuessedGlossLabel(_ gloss: String) -> UILabel {
        let line = NSMutableAttributedString(
            string: gloss,
            attributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.label]
        )
        line.append(NSAttributedString(
            string: "  ·  guess",
            attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.tertiaryLabel]
        ))
        let label = UILabel()
        label.attributedText = line
        label.numberOfLines = 0
        label.textAlignment = .natural
        label.preferredMaxLayoutWidth = sheetContentWidth()
        return label
    }

    // Builds a small section header label.
    func makeSheetSectionHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabel
        return label
    }

    // Builds a body label for multi-line debug content.
    func makeSheetBodyLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        return label
    }

    // Rebuilds the middle content section with the most common definition gloss.
    // Hides the container when there is no content to display.
    // The parent view controller is used to present nested component lookup sheets.
    // selectedReading and selectedKanji filter senses via JMdict stagk/stagr restrictions so the
    // gloss matches the form the user is actually looking at — e.g. 様 read as よう shows
    // "appearance, manner" rather than 様's primary sense ("Mr/Mrs/Miss/Ms", which is stagr=さま).
    func updateMiddleContent(
        in middleContentStack: UIStackView,
        parent: UIViewController? = nil,
        selectedReading: String? = nil,
        selectedKanji: String? = nil,
        surface: String? = nil
    ) {
        for subview in middleContentStack.arrangedSubviews {
            middleContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        // An ambiguous form nobody has picked a word for yet: the possibilities alone, no meaning.
        if currentSheetLookupCandidates.count > 1, currentSheetDictionaryEntry == nil {
            addLookupCandidateRows(to: middleContentStack, parent: parent)
            middleContentStack.superview?.isHidden = false
            return
        }

        let visibleSenses = currentSheetDictionaryEntry?
            .senses(forReading: selectedReading, kanji: selectedKanji)
            .filter { $0.glosses.isEmpty == false } ?? []
        guard visibleSenses.isEmpty == false else {
            // No dictionary on disk yet (first launch, or a new release still downloading): a
            // spinner instead of an empty sheet. The sheet is refreshed once the store is rebuilt.
            if DictionaryDownloadManager.isInstalled == false {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                middleContentStack.addArrangedSubview(spinner)
                middleContentStack.superview?.isHidden = false
                return
            }
            // No entry: show a guessed gloss instead, with a spinner while it's fetched.
            if let surface, let glossGuessProvider {
                showGuessedGloss(for: surface, in: middleContentStack, parent: parent, provider: glossGuessProvider)
                return
            }
            middleContentStack.superview?.isHidden = true
            return
        }

        let measuredContentWidth = sheetContentWidth()

        // Every word an ambiguous form can be (いった → 言う / 行く / 要る), above the shown word's senses.
        addLookupCandidateRows(to: middleContentStack, parent: parent)

        // Compact most-common-meanings list: JMdict orders senses by commonness, so the top
        // senses in array order are the word's dominant meanings. The primary sense renders
        // full-size; later senses render smaller and dimmer so the dominant meaning stays
        // scannable at a glance. Caps keep the sheet detent short for polysemous words
        // (する has 10+ senses); full sense detail lives in the word-detail screen.
        let senseList = UIStackView()
        senseList.axis = .vertical
        senseList.spacing = 4
        senseList.alignment = .fill
        var previousPos: String? = nil
        for (index, sense) in visibleSenses.prefix(maxVisibleSheetSenses).enumerated() {
            let senseLabel = makeSheetSenseLabel(
                sense,
                number: visibleSenses.count > 1 ? index + 1 : nil,
                isPrimary: index == 0,
                // JMdict pos carries forward across senses, so only tag a line when its pos
                // differs from the line above — repeating "noun" per line is noise.
                showsPos: sense.pos != previousPos,
                maxLayoutWidth: measuredContentWidth
            )
            senseList.addArrangedSubview(senseLabel)
            previousPos = sense.pos
        }
        if visibleSenses.count > maxVisibleSheetSenses {
            let moreLabel = UILabel()
            moreLabel.text = "+\(visibleSenses.count - maxVisibleSheetSenses) more"
            moreLabel.font = .systemFont(ofSize: 11, weight: .medium)
            moreLabel.textColor = .tertiaryLabel
            senseList.addArrangedSubview(moreLabel)
        }
        middleContentStack.addArrangedSubview(senseList)

        // Compound verb components: shows each lemma + first gloss as a tappable row when the
        // surface contains a main verb + auxiliary (e.g. 消えてゆく → 消える: to disappear /
        // 行く: to go). Vertical list with lemma + definition inline so the user can see what
        // each part means without drilling into a sub-sheet first.
        if currentSheetCompoundComponents.count > 1 {
            let separator = UIView()
            separator.backgroundColor = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            let hairlineScale = middleContentStack.traitCollection.displayScale
            separator.heightAnchor.constraint(equalToConstant: 1 / (hairlineScale > 0 ? hairlineScale : 2)).isActive = true
            middleContentStack.addArrangedSubview(separator)

            let headerLabel = makeSheetSectionHeader("Compound")
            middleContentStack.addArrangedSubview(headerLabel)

            for component in currentSheetCompoundComponents {
                let lemmaLabel = UILabel()
                lemmaLabel.text = component.lemma
                lemmaLabel.font = .systemFont(ofSize: 15, weight: .medium)
                lemmaLabel.textColor = .label
                lemmaLabel.setContentHuggingPriority(.required, for: .horizontal)
                lemmaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

                let glossLabel = UILabel()
                glossLabel.text = component.gloss?
                    .components(separatedBy: ";").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                glossLabel.font = .systemFont(ofSize: 14)
                glossLabel.textColor = .secondaryLabel
                glossLabel.numberOfLines = 0
                // The component row reserves the lemma label's intrinsic width plus 10pt spacing,
                // so the gloss label wraps inside the remaining width — give Auto Layout a hint.
                glossLabel.preferredMaxLayoutWidth = max(120, measuredContentWidth - 80)

                let row = UIStackView(arrangedSubviews: [lemmaLabel, glossLabel])
                row.axis = .horizontal
                row.spacing = 10
                row.alignment = .firstBaseline
                row.isUserInteractionEnabled = true

                let tap = ClosureTapGesture { [weak self, weak parent] in
                    guard let self, let parent else { return }
                    if let handler = self.onCompoundComponentTapped {
                        handler(component.lemma, component.gloss)
                    } else {
                        // Fallback for contexts that haven't wired the full-chrome handler.
                        self.presentComponentSheet(surface: component.lemma, gloss: component.gloss, from: parent)
                    }
                }
                row.addGestureRecognizer(tap)
                middleContentStack.addArrangedSubview(row)
            }
        }

        middleContentStack.superview?.isHidden = false
    }
}
