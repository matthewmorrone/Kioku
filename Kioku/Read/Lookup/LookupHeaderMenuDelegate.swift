import UIKit

// Long-press Copy / Copy Reading / Share for the lookup sheet's headword, so a looked-up word can
// leave the app. Reads the surface and reading through closures because both change while the
// sheet stays open (merge, split, reading arrows).
final class LookupHeaderMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    private let surface: () -> String
    private let reading: () -> String?
    private weak var presenter: UIViewController?

    // Captures the live surface/reading providers and the controller that presents the share sheet.
    init(surface: @escaping () -> String, reading: @escaping () -> String?, presenter: UIViewController) {
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
        let shownReading = reading()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = word
                }
            ]
            if let shownReading, shownReading.isEmpty == false, shownReading != word {
                actions.append(UIAction(title: "Copy Reading", image: UIImage(systemName: "character.phonetic.ja")) { _ in
                    UIPasteboard.general.string = shownReading
                })
            }
            actions.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                self?.share(word, from: interaction.view)
            })
            return UIMenu(title: "", children: actions)
        }
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
