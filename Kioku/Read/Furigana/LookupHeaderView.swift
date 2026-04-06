import SwiftUI
import UIKit

// UIViewRepresentable that renders the lookup-sheet header row using the same UIKit stack
// as SegmentLookupSheet — per-kanji-run ruby labels above headword labels in an HStack.
// Used by SegmentLookupSheetHeader so the SwiftUI header matches the native sheet exactly.
struct LookupHeaderView: UIViewRepresentable {
    let surface: String
    let reading: String?
    let lemma: String?

    private let headwordFont = UIFont.systemFont(ofSize: 34, weight: .bold)
    private let rubyFont = UIFont.systemFont(ofSize: 17)

    func makeUIView(context: Context) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        return stack
    }

    func updateUIView(_ stack: UIStackView, context: Context) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let headerRow = buildHeaderRow()
        stack.addArrangedSubview(headerRow)

        if let lemma, lemma != surface {
            let lemmaLabel = UILabel()
            lemmaLabel.font = UIFont.preferredFont(forTextStyle: .title3)
            lemmaLabel.textColor = .secondaryLabel
            lemmaLabel.textAlignment = .center
            lemmaLabel.text = lemma
            stack.addArrangedSubview(lemmaLabel)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIStackView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.window?.screen.bounds.width ?? 390
        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }

    // Builds a horizontal row of per-segment columns: ruby label above headword label.
    // Matches the layout produced by SegmentLookupSheet.buildSheetHeaderSubviews exactly.
    private func buildHeaderRow() -> UIStackView {
        let subviews = buildSegmentColumns()

        let row = UIStackView(arrangedSubviews: subviews.isEmpty ? [plainHeadwordLabel()] : subviews)
        row.axis = .horizontal
        row.alignment = .bottom
        row.spacing = 0
        return row
    }

    // Returns one column per segment (kanji run or kana run).
    private func buildSegmentColumns() -> [UIView] {
        let chars = Array(surface)
        let runs = FuriganaAttributedString.kanjiRuns(in: surface)
        let readings = reading.flatMap {
            FuriganaAttributedString.normalizedRunReadings(surface: surface, reading: $0, runs: runs)
        }

        struct Segment { let text: String; let ruby: String? }
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

    private func plainHeadwordLabel() -> UILabel {
        let label = UILabel()
        label.font = headwordFont
        label.text = surface
        label.textAlignment = .center
        return label
    }
}
