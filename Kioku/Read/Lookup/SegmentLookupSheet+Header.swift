import UIKit

extension SegmentLookupSheet {
    // Builds a header row for the lookup sheet with per-kanji-run furigana centered above each headword.
    func buildSheetHeaderSubviews(
        surface: String,
        reading: String?,
        headwordFont: UIFont = UIFont.systemFont(ofSize: 34, weight: .bold),
        rubyFont: UIFont = UIFont.systemFont(ofSize: 17)
    ) -> [UIView] {
        let chars = Array(surface)
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        let readings = reading.flatMap {
            FuriganaAttributedString.normalizedRunReadings(surface: surface, reading: $0, runs: runs)
        }

        struct Segment {
            let text: String
            let ruby: String?
        }

        var segments: [Segment] = []
        var cursor = 0
        for (index, run) in runs.enumerated() {
            if cursor < run.start {
                segments.append(Segment(text: String(chars[cursor..<run.start]), ruby: nil))
            }
            let kanjiText = String(chars[run.start..<run.end])
            let ruby = readings.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            segments.append(Segment(text: kanjiText, ruby: (ruby != nil && ruby != kanjiText) ? ruby : nil))
            cursor = run.end
        }

        if cursor < chars.count {
            segments.append(Segment(text: String(chars[cursor...]), ruby: nil))
        }

        if segments.isEmpty {
            let label = UILabel()
            label.font = headwordFont
            label.text = surface
            label.textAlignment = .center
            return [label]
        }

        return segments.map { segment in
            let headwordLabel = UILabel()
            headwordLabel.font = headwordFont
            headwordLabel.text = segment.text
            headwordLabel.textAlignment = .center

            let rubyLabel = UILabel()
            rubyLabel.font = rubyFont
            rubyLabel.textColor = .secondaryLabel
            rubyLabel.textAlignment = .center
            rubyLabel.text = segment.ruby
            rubyLabel.alpha = segment.ruby != nil ? 1 : 0
            rubyLabel.heightAnchor.constraint(equalToConstant: ceil(rubyFont.lineHeight)).isActive = true

            let column = UIStackView(arrangedSubviews: [rubyLabel, headwordLabel])
            column.axis = .vertical
            column.alignment = .center
            column.spacing = 2
            return column
        }
    }

    // Creates the header container used at the top of the lookup sheet.
    func makeSheetHeaderView(surface: String, initialReading: String?) -> (stack: UIStackView, row: UIStackView, lemmaLabel: UILabel) {
        let headerRow = UIStackView(arrangedSubviews: buildSheetHeaderSubviews(surface: surface, reading: initialReading))
        headerRow.axis = .horizontal
        headerRow.alignment = .bottom
        headerRow.spacing = 0

        let headerStack = UIStackView(arrangedSubviews: [headerRow])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .vertical
        headerStack.alignment = .center
        headerStack.spacing = 2

        let lemmaLabel = UILabel()
        lemmaLabel.font = UIFont.preferredFont(forTextStyle: .title3)
        lemmaLabel.textColor = .secondaryLabel
        lemmaLabel.textAlignment = .center
        lemmaLabel.isHidden = true
        headerStack.addArrangedSubview(lemmaLabel)

        return (headerStack, headerRow, lemmaLabel)
    }

    // Rebuilds the header row when the selected surface or reading changes.
    func rebuildSheetHeaderRow(_ headerRow: UIStackView, surface: String, reading: String?) {
        headerRow.arrangedSubviews.forEach { subview in
            headerRow.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        for view in buildSheetHeaderSubviews(surface: surface, reading: reading) {
            headerRow.addArrangedSubview(view)
        }
    }
}
