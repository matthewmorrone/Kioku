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

    // Rebuilds the middle content section with ranked paths and dictionary senses.
    func updateMiddleContent(in middleContentStack: UIStackView) {
        for subview in middleContentStack.arrangedSubviews {
            middleContentStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let sublatticeEdges = currentSheetSublatticeEdges
        if sublatticeEdges.isEmpty == false {
            func segmentScore(_ segment: String) -> Double {
                pathSegmentFrequencyProvider?(segment).flatMap { normalizedSheetFrequencyScore($0) } ?? 0
            }

            let paths = sublatticeValidPaths(from: sublatticeEdges)
                .sorted { lhs, rhs in
                    let lScore = lhs.map(segmentScore).reduce(0, +) / max(1, Double(lhs.count))
                    let rScore = rhs.map(segmentScore).reduce(0, +) / max(1, Double(rhs.count))
                    return lScore > rScore
                }

            if paths.isEmpty == false {
                middleContentStack.addArrangedSubview(makeSheetSectionHeader("Paths"))
                let pathLines = paths.map { path -> String in
                    let score = path.map(segmentScore).reduce(0, +) / max(1, Double(path.count))
                    return path.joined(separator: " · ") + "  [\(String(format: "%.2f", score))]"
                }.joined(separator: "\n")
                middleContentStack.addArrangedSubview(makeSheetBodyLabel(pathLines))
            }
        }

        guard let entry = currentSheetDictionaryEntry else { return }
        let senses = entry.senses
        guard senses.isEmpty == false else { return }

        for (index, sense) in senses.enumerated() {
            let glossText = sense.glosses.joined(separator: "; ")
            guard glossText.isEmpty == false else { continue }

            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline

            let numberLabel = UILabel()
            numberLabel.text = "\(index + 1)."
            numberLabel.font = .systemFont(ofSize: 14, weight: .medium)
            numberLabel.textColor = .tertiaryLabel
            numberLabel.setContentHuggingPriority(.required, for: .horizontal)
            numberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            let glossLabel = UILabel()
            glossLabel.text = glossText
            glossLabel.font = .systemFont(ofSize: 15)
            glossLabel.textColor = .label
            glossLabel.numberOfLines = 0

            row.addArrangedSubview(numberLabel)
            row.addArrangedSubview(glossLabel)
            middleContentStack.addArrangedSubview(row)
        }
    }
}
