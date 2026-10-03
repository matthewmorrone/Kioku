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

        // A long segment (なって憤り出しました) is wider than the header at full size, and the row
        // would otherwise truncate its last column to "…". Shrink both fonts by the same factor
        // until every column — the wider of its glyphs and its ruby — fits.
        let neededWidth = segments.reduce(CGFloat(0)) { total, segment in
            let glyphWidth = (segment.text as NSString).size(withAttributes: [.font: headwordFont]).width
            let rubyWidth = (segment.ruby as NSString?)?.size(withAttributes: [.font: rubyFont]).width ?? 0
            return total + ceil(max(glyphWidth, rubyWidth))
        }
        let fitScale = min(1, sheetHeaderAvailableWidth() / max(neededWidth, 1))
        let headwordFont = headwordFont.withSize(floor(headwordFont.pointSize * fitScale))
        let rubyFont = rubyFont.withSize(floor(rubyFont.pointSize * fitScale))

        // No kanji run means no furigana can ever appear here, so don't reserve the ruby line
        // above the headword. (Kanji words keep the reserve: their reading arrives a moment
        // after the sheet opens, and the header must not jump when it does.)
        if runs.isEmpty {
            let label = UILabel()
            label.font = headwordFont
            label.text = surface
            label.textAlignment = .center
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            return [label]
        }

        return segments.map { segment in
            let headwordLabel = UILabel()
            headwordLabel.font = headwordFont
            headwordLabel.text = segment.text
            headwordLabel.textAlignment = .center
            // The headword is the one thing in the sheet that must never be shortened: a label
            // squeezed below its line height renders a vertically centred slice of the glyphs.
            // Any height the sheet is short comes out of the definitions area instead (see
            // buildMiddleContent, which drops its vertical compression resistance to match).
            headwordLabel.setContentCompressionResistancePriority(.required, for: .vertical)

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

    // Width the header row gets inside the sheet: the screen less the header container's 16 pt
    // margins and the 36 pt reading chevrons (each with 8 pt of clearance) on either side. Must
    // track the constraints in SurfaceSheetViewController+Build.
    func sheetHeaderAvailableWidth() -> CGFloat {
        activeScreenBounds().width - (16 * 2) - ((36 + 8) * 2)
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
