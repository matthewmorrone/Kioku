import UIKit
import CoreText

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

    // Applies a kana reading as a ruby annotation above the surface text using Core Text.
    // Falls back to plain text when reading is nil, empty, or the surface contains no kanji.
    func applyFurigana(surface: String, reading: String?) {
        guard let reading, reading.isEmpty == false else {
            attributedText = nil
            text = surface
            return
        }

        let rubyAnnotation = CTRubyAnnotationCreateWithAttributes(
            .auto, .auto, .before,
            reading as CFString,
            [kCTRubyAnnotationSizeFactorAttributeName: 0.5] as CFDictionary
        )

        let currentFont = font ?? UIFont.systemFont(ofSize: UIFont.labelFontSize)
        let attrString = NSMutableAttributedString(
            string: surface,
            attributes: [
                .font: currentFont,
                .foregroundColor: textColor ?? UIColor.label,
                NSAttributedString.Key(kCTRubyAnnotationAttributeName as String): rubyAnnotation
            ]
        )
        attributedText = attrString
    }

    // Copies the label text to the shared pasteboard.
    @objc private func copyText() {
        UIPasteboard.general.string = text
    }

    // Presents a share sheet for the label text via the nearest view controller.
    private func shareText() {
        guard let text, text.isEmpty == false else { return }
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        // On iPad, anchor the popover to this view to avoid a crash.
        activityVC.popoverPresentationController?.sourceView = self
        activityVC.popoverPresentationController?.sourceRect = bounds
        guard let root = window?.rootViewController else { return }
        root.topmostPresentedViewController.present(activityVC, animated: true)
    }

    // Provides copy and share actions on long press so the label stays visually quiet.
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
            let shareAction = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.shareText()
            }

            return UIMenu(title: "", children: [copyAction, shareAction])
        }
    }
}

// Walks the presented-VC chain to find the topmost controller for sheet presentation.
private extension UIViewController {
    var topmostPresentedViewController: UIViewController {
        presentedViewController?.topmostPresentedViewController ?? self
    }
}