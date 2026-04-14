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
        middleContentStack.superview?.isHidden = false
    }
}
