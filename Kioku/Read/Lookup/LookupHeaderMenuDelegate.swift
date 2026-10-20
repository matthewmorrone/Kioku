import UIKit

// Long-press Copy (headword / reading submenu) / Share on the lookup sheet's headword, so a looked-up word can
// leave the app; Edit Reading on a press of its furigana. Reads the surface and reading through closures because both change while the
// sheet stays open (merge, split, reading arrows).
final class LookupHeaderMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    // View tag marking a furigana label, so a press on it can be told from one on the headword.
    static let rubyTag = 7001
    private let surface: () -> String
    private let reading: () -> String?
    private let canEditReading: () -> Bool
    private let editReading: () -> Void
    private weak var presenter: UIViewController?
    // When the long press last began or its menu last closed. The header's tap (custom reading) must
    // not fire off the same touch, so it asks isTapSuppressed before acting.
    private var lastMenuEventAt: Date?
    private var isMenuOpen = false

    // True while the menu is open or just closed, so the touch that opened or dismissed it is not
    // also read as a tap on the header.
    var isTapSuppressed: Bool {
        isMenuOpen || (lastMenuEventAt.map { Date().timeIntervalSince($0) < 0.8 } ?? false)
    }

    // Captures the live surface/reading providers and the controller that presents the share sheet.
    init(
        surface: @escaping () -> String,
        reading: @escaping () -> String?,
        canEditReading: @escaping () -> Bool,
        editReading: @escaping () -> Void,
        presenter: UIViewController
    ) {
        self.canEditReading = canEditReading
        self.editReading = editReading
        self.surface = surface
        self.reading = reading
        self.presenter = presenter
    }

    // Builds the menu at press time so it reflects the surface and reading shown right now.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let word = surface()
        guard word.isEmpty == false else { return nil }
        lastMenuEventAt = Date()
        // A press on the furigana is the reading's menu; anywhere else is the headword's.
        if interaction.view?.hitTest(location, with: nil)?.tag == Self.rubyTag {
            guard canEditReading() else { return nil }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(title: "", children: [
                    UIAction(title: "Edit Reading", image: UIImage(systemName: "pencil")) { _ in self?.editReading() }
                ])
            }
        }
        let shownReading = reading()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            let copyWord = UIAction(title: word, image: UIImage(systemName: "textformat")) { _ in
                UIPasteboard.general.string = word
            }
            if let shownReading, shownReading.isEmpty == false, shownReading != word {
                // One Copy entry; its submenu offers the headword and the reading.
                let copyReading = UIAction(title: shownReading, image: UIImage(systemName: "character.phonetic.ja")) { _ in
                    UIPasteboard.general.string = shownReading
                }
                actions.append(UIMenu(title: "Copy", image: UIImage(systemName: "doc.on.doc"), children: [copyWord, copyReading]))
            } else {
                actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = word
                })
            }
            actions.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self?.share(word, from: interaction.view)
            })
            return UIMenu(title: "", children: actions)
        }
    }

    // Marks the menu open so the press that opened it never counts as a tap.
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        isMenuOpen = true
        lastMenuEventAt = Date()
    }

    // Marks the menu closed; the dismissing touch is still suppressed for a moment (isTapSuppressed).
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionAnimating?
    ) {
        isMenuOpen = false
        lastMenuEventAt = Date()
    }

    // Presents the system share sheet from the sheet controller, anchored to the header for iPad.
    private func share(_ text: String, from anchor: UIView?) {
        guard let presenter else { return }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = anchor
        activity.popoverPresentationController?.sourceRect = anchor?.bounds ?? .zero
        presenter.present(activity, animated: true)
    }
}
