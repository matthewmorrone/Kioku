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
    // a spinner while it's being fetched, and a Learn Spelling button. Starts the fetch the first
    // time a surface shows up here and re-renders the sheet when it lands.
    private func showGuessedGloss(
        for surface: String,
        in middleContentStack: UIStackView,
        parent: UIViewController?,
        provider: (@MainActor (String) async -> String?)?
    ) {
        if let provider, guessedGlossSurface != surface {
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
        var hasContent = false
        if let guessedGloss, guessedGlossSurface == surface {
            middleContentStack.addArrangedSubview(makeGuessedGlossRow(
                guessedGloss,
                explanation: "「\(surface)」 isn't in Kioku's dictionary, so AI guessed this meaning from the line it appears in, and from the song breakdown when there is one. It can be wrong.",
                parent: parent
            ))
            hasContent = true
        } else if glossGuessTask != nil {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            middleContentStack.addArrangedSubview(spinner)
            hasContent = true
        }
        if let learnSpellingHandler {
            middleContentStack.addArrangedSubview(makeLearnSpellingButton(for: surface, handler: learnSpellingHandler))
            hasContent = true
        }
        middleContentStack.superview?.isHidden = hasContent == false
    }

    // The Learn Spelling button under an unknown word's guess.
    private func makeLearnSpellingButton(for surface: String, handler: @escaping @MainActor (String) -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = "Learn Spelling"
        configuration.image = UIImage(systemName: "character.book.closed")
        configuration.imagePadding = 6
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in handler(surface) }, for: .touchUpInside)
        return button
    }

    // A guessed gloss, styled like a primary sense, with an ⓘ button beside it that explains where
    // the guess came from (`explanation`) in an alert over `parent`. Also the whole-form meaning
    // above an inflected word's senses.
    func makeGuessedGlossRow(_ gloss: String, explanation: String, parent: UIViewController?) -> UIView {
        let label = UILabel()
        label.text = gloss
        label.font = .systemFont(ofSize: 15)
        label.textColor = .label
        label.numberOfLines = 0
        label.textAlignment = .natural
        label.preferredMaxLayoutWidth = sheetContentWidth() - 28

        let infoButton = UIButton(type: .system)
        infoButton.setImage(
            UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)),
            for: .normal
        )
        infoButton.tintColor = .tertiaryLabel
        infoButton.accessibilityLabel = "Where this meaning comes from"
        infoButton.setContentHuggingPriority(.required, for: .horizontal)
        infoButton.addAction(UIAction { [weak parent] _ in
            let alert = UIAlertController(title: "AI Guess", message: explanation, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            parent?.present(alert, animated: true)
        }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [label, infoButton, UIView()])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .center
        return row
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
            if let surface, glossGuessProvider != nil || learnSpellingHandler != nil {
                showGuessedGloss(for: surface, in: middleContentStack, parent: parent, provider: glossGuessProvider)
                return
            }
            middleContentStack.superview?.isHidden = true
            return
        }

        let measuredContentWidth = sheetContentWidth()

        // Every word an ambiguous form can be (いった → 言う / 行く / 要る), above the shown word's senses.
        addLookupCandidateRows(to: middleContentStack, parent: parent)

        // What the whole form means (言いたくない → to not want to say), above the lemma's senses.
        if let surface {
            addCompositeGloss(for: surface, primarySense: visibleSenses[0], to: middleContentStack, parent: parent)
        }

        // A form built from several words (起こる + そう, 消える + ゆく) shows each word with its
        // meaning on one line instead of the first word's senses, which that line already gives.
        // A word with its own entry (思い出す) keeps its senses and gets the line underneath.
        let showsComponents = currentSheetCompoundComponents.count > 1
        let surfaceHasOwnEntry = surface.map { currentSheetDictionaryEntryDefines($0) } ?? false
        if showsComponents, surfaceHasOwnEntry == false {
            middleContentStack.addArrangedSubview(makeComponentEquationRow(currentSheetCompoundComponents, parent: parent))
            middleContentStack.superview?.isHidden = false
            return
        }

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
        if showsComponents {
            middleContentStack.addArrangedSubview(makeComponentEquationRow(currentSheetCompoundComponents, parent: parent))
        }

        middleContentStack.superview?.isHidden = false
    }
}
