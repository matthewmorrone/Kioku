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
    func updateMiddleContent(in middleContentStack: UIStackView) {
        for subview in middleContentStack.arrangedSubviews {
            middleContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        guard let entry = currentSheetDictionaryEntry,
              let firstGloss = entry.senses.first?.glosses.joined(separator: "; "),
              firstGloss.isEmpty == false else {
            middleContentStack.superview?.isHidden = true
            return
        }

        let glossLabel = UILabel()
        glossLabel.text = firstGloss
        glossLabel.font = .systemFont(ofSize: 15)
        glossLabel.textColor = .label
        glossLabel.numberOfLines = 0
        glossLabel.textAlignment = .natural
        middleContentStack.addArrangedSubview(glossLabel)

        // Compound verb components: shows each lemma as a tappable row when the surface
        // contains a main verb + auxiliary (e.g. 消えてゆく → 消える + 行く).
        if currentSheetCompoundComponents.count > 1 {
            let separator = UIView()
            separator.backgroundColor = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            let hairlineScale = middleContentStack.traitCollection.displayScale
            separator.heightAnchor.constraint(equalToConstant: 1 / (hairlineScale > 0 ? hairlineScale : 2)).isActive = true
            middleContentStack.addArrangedSubview(separator)

            let headerLabel = makeSheetSectionHeader("Compound")
            middleContentStack.addArrangedSubview(headerLabel)

            let componentsRow = UIStackView()
            componentsRow.axis = .horizontal
            componentsRow.spacing = 6
            componentsRow.alignment = .center

            for (index, component) in currentSheetCompoundComponents.enumerated() {
                if index > 0 {
                    let plus = UILabel()
                    plus.text = "+"
                    plus.font = .systemFont(ofSize: 13, weight: .medium)
                    plus.textColor = .tertiaryLabel
                    plus.setContentHuggingPriority(.required, for: .horizontal)
                    componentsRow.addArrangedSubview(plus)
                }

                let chip = UIButton(type: .system)
                chip.setTitle(component.lemma, for: .normal)
                chip.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                chip.setTitleColor(.label, for: .normal)
                var config = UIButton.Configuration.plain()
                config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
                chip.configuration = config
                chip.backgroundColor = .secondarySystemFill
                chip.layer.cornerRadius = 8
                chip.setContentHuggingPriority(.defaultLow, for: .horizontal)
                // TODO: wire tap to open dictionary detail for this component
                componentsRow.addArrangedSubview(chip)
            }

            componentsRow.addArrangedSubview(UIView()) // trailing spacer
            middleContentStack.addArrangedSubview(componentsRow)
        }

        middleContentStack.superview?.isHidden = false
    }
}
