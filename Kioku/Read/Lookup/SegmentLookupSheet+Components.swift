import UIKit

extension SegmentLookupSheet {
    // The words a form is built from as its own section: a hairline, then the
    // chips centred on a line of their own, set apart from the senses above.
    func makeComponentSection(_ components: [(lemma: String, gloss: String?)], parent: UIViewController?) -> UIView {
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true

        let section = UIStackView(arrangedSubviews: [separator, makeComponentEquationRow(components, parent: parent)])
        section.axis = .vertical
        section.spacing = 8
        section.alignment = .fill
        return section
    }

    // The words a form is built from, side by side with "+" between them (起こる to occur +
    // そう seeming that): each word over its first gloss, wrapping within its share of the width.
    // Tapping a word drills into its own lookup.
    func makeComponentEquationRow(_ components: [(lemma: String, gloss: String?)], parent: UIViewController?) -> UIView {
        // Each column's share of the sheet after the "+" separators, so a long gloss wraps in its
        // own column (and the sheet detent measures the wrapped height) instead of crowding the rest.
        let count = CGFloat(max(components.count, 1))
        let columnWidth = (sheetContentWidth() - (count - 1) * 30) / count - 2 * Self.componentChipPadding.width
        var views: [UIView] = []
        for (index, component) in components.enumerated() {
            if index > 0 {
                let plus = UILabel()
                plus.text = "+"
                plus.font = .systemFont(ofSize: 15)
                plus.textColor = .label
                plus.setContentHuggingPriority(.required, for: .horizontal)
                plus.setContentCompressionResistancePriority(.required, for: .horizontal)
                views.append(plus)
            }
            let column = makeComponentColumn(component, maxWidth: columnWidth, parent: parent)
            column.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            views.append(column)
        }
        // The "+" signs sit on the chips' vertical centre, and the row is centred in the sheet.
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        let holder = UIView()
        holder.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: holder.topAnchor),
            row.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            row.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: holder.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
        ])
        return holder
    }

    // Inner padding of a word's chip (horizontal, vertical).
    private static let componentChipPadding = CGSize(width: 10, height: 6)

    // One word of the row: the word over its first gloss on a rounded chip, tappable.
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
        glossLabel.textColor = .label
        glossLabel.numberOfLines = 0
        glossLabel.textAlignment = .center
        glossLabel.preferredMaxLayoutWidth = maxWidth

        let column = UIStackView(arrangedSubviews: [lemmaLabel, glossLabel])
        column.axis = .vertical
        column.spacing = 2
        column.alignment = .center
        column.isUserInteractionEnabled = true
        column.isLayoutMarginsRelativeArrangement = true
        column.layoutMargins = UIEdgeInsets(
            top: Self.componentChipPadding.height,
            left: Self.componentChipPadding.width,
            bottom: Self.componentChipPadding.height,
            right: Self.componentChipPadding.width
        )
        column.backgroundColor = .tertiarySystemFill
        column.layer.cornerRadius = 10
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
