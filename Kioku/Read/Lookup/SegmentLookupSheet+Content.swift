import UIKit

extension SegmentLookupSheet {
    // Converts frequency data to a unified Zipf-equivalent score (higher = more frequent).
    // jpdbRank is preferred; wordfreqZipf used as fallback. Both land on a ~0–7 scale.
    func normalizedSheetFrequencyScore(_ data: [String: FrequencyData]) -> Double? {
        if let rank = data.values.compactMap({ $0.jpdbRank }).min() {
            return max(0.0, 7.0 - log10(Double(rank)))
        }
        return data.values.compactMap({ $0.wordfreqZipf }).max()
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
        selectedKanji: String? = nil
    ) {
        for subview in middleContentStack.arrangedSubviews {
            middleContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        guard let entry = currentSheetDictionaryEntry,
              let firstGloss = entry.sense(forReading: selectedReading, kanji: selectedKanji)?
                .glosses.joined(separator: "; "),
              firstGloss.isEmpty == false else {
            middleContentStack.superview?.isHidden = true
            return
        }

        // Multi-line UILabels need preferredMaxLayoutWidth set before the first systemLayoutSizeFitting
        // pass so the detent resolver gets the wrapped height instead of single-line height. Without
        // it, the sheet detent renders at single-line height and the wrapped definition is clipped.
        // The lookup sheet is full-width; subtract container/stack padding to land on the label's
        // actual rendered width.
        let measuredContentWidth = max(200, activeScreenBounds().width) - (16 * 2) - (6 * 2)

        let glossLabel = UILabel()
        glossLabel.text = firstGloss
        glossLabel.font = .systemFont(ofSize: 15)
        glossLabel.textColor = .label
        glossLabel.numberOfLines = 0
        glossLabel.textAlignment = .natural
        glossLabel.preferredMaxLayoutWidth = measuredContentWidth
        middleContentStack.addArrangedSubview(glossLabel)

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
