import UIKit

// Renders label-style text that supports long-press copy without text-selection UI.
final class CopyableLabel: UILabel, UIContextMenuInteractionDelegate {
    // Initializes the copyable label for programmatic UIKit layouts.
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureCopyInteraction()
    }

    // Initializes the copyable label from archived UIKit state.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCopyInteraction()
    }

    // Enables long-press copy while preserving normal label appearance.
    private func configureCopyInteraction() {
        isUserInteractionEnabled = true
        let contextMenuInteraction = UIContextMenuInteraction(delegate: self)
        addInteraction(contextMenuInteraction)
    }

    // Copies the label text to the shared pasteboard.
    @objc private func copyText() {
        UIPasteboard.general.string = text
    }

    // Provides a copy-only long-press menu so the label stays visually quiet.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let text, text.isEmpty == false else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copyText()
            }

            return UIMenu(title: "", children: [copyAction])
        }
    }
}