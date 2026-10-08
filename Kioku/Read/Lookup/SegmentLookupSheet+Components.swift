import UIKit

extension SegmentLookupSheet {
    // The words a form is built from, side by side with "+" between them (起こる to occur +
    // そう seeming that): each word over its first gloss, wrapping within its share of the width.
    // Tapping a word drills into its own lookup.
    func makeComponentEquationRow(_ components: [(lemma: String, gloss: String?)], parent: UIViewController?) -> UIView {
        // Each column's share of the sheet after the "+" separators, so a long gloss wraps in its
        // own column (and the sheet detent measures the wrapped height) instead of crowding the rest.
        let count = CGFloat(max(components.count, 1))
        let columnWidth = (sheetContentWidth() - (count - 1) * 30) / count
        var views: [UIView] = []
        for (index, component) in components.enumerated() {
            if index > 0 {
                let plus = UILabel()
                plus.text = "+"
                plus.font = .systemFont(ofSize: 15)
                plus.textColor = .tertiaryLabel
                plus.setContentHuggingPriority(.required, for: .horizontal)
                plus.setContentCompressionResistancePriority(.required, for: .horizontal)
                views.append(plus)
            }
            let column = makeComponentColumn(component, maxWidth: columnWidth, parent: parent)
            column.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            views.append(column)
        }
        // The row spans the sheet; this takes the leftover width so the words sit together on the
        // left instead of the first column stretching and pushing the rest to the right edge.
        let trailingSpace = UIView()
        trailingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(trailingSpace)
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }

    // One word of the row: the word over its first gloss, tappable.
    private func makeComponentColumn(_ component: (lemma: String, gloss: String?), maxWidth: CGFloat, parent: UIViewController?) -> UIView {
        let lemmaLabel = UILabel()
        lemmaLabel.text = component.lemma
        lemmaLabel.font = .systemFont(ofSize: 15, weight: .medium)
        lemmaLabel.textColor = .label

        let glossLabel = UILabel()
        glossLabel.text = component.gloss?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        glossLabel.font = .systemFont(ofSize: 14)
        glossLabel.textColor = .secondaryLabel
        glossLabel.numberOfLines = 0
        glossLabel.preferredMaxLayoutWidth = maxWidth

        let column = UIStackView(arrangedSubviews: [lemmaLabel, glossLabel])
        column.axis = .vertical
        column.spacing = 2
        column.alignment = .leading
        column.isUserInteractionEnabled = true
        column.addGestureRecognizer(ClosureTapGesture { [weak self, weak parent] in
            guard let self, let parent else { return }
            if let handler = self.onCompoundComponentTapped {
                handler(component.lemma, component.gloss)
            } else {
                // Fallback for contexts that haven't wired the full-chrome handler.
                self.presentComponentSheet(surface: component.lemma, gloss: component.gloss, from: parent)
            }
        })
        return column
    }
}
