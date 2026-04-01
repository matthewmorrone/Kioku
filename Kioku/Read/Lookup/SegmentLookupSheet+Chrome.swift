import UIKit

extension SegmentLookupSheet {
    // Builds the custom top handle used to dismiss the sheet without enabling pan-to-dismiss everywhere.
    func makeSheetDismissHandleButton() -> UIButton {
        let dismissHandleButton = UIButton(type: .custom)
        dismissHandleButton.translatesAutoresizingMaskIntoConstraints = false
        dismissHandleButton.backgroundColor = .clear
        dismissHandleButton.accessibilityLabel = "Dismiss"

        let dismissHandleBar = UIView()
        dismissHandleBar.translatesAutoresizingMaskIntoConstraints = false
        dismissHandleBar.backgroundColor = .tertiaryLabel.withAlphaComponent(0.65)
        dismissHandleBar.layer.cornerRadius = 2.5
        dismissHandleBar.isUserInteractionEnabled = false
        dismissHandleButton.addSubview(dismissHandleBar)

        NSLayoutConstraint.activate([
            dismissHandleBar.centerXAnchor.constraint(equalTo: dismissHandleButton.centerXAnchor),
            dismissHandleBar.centerYAnchor.constraint(equalTo: dismissHandleButton.centerYAnchor),
            dismissHandleBar.widthAnchor.constraint(equalToConstant: 36),
            dismissHandleBar.heightAnchor.constraint(equalToConstant: 5),
        ])

        dismissHandleButton.addAction(
            UIAction { [weak self] _ in
                self?.dismissPopover()
            },
            for: .touchUpInside
        )

        return dismissHandleButton
    }

    // Returns the fixed chrome height outside the middle content and optional split panel.
    func surfaceSheetBaseChromeHeight(headerHeight: CGFloat, safeArea: UIEdgeInsets) -> CGFloat {
        safeArea.top + 28 + 12 + headerHeight + 8 + 16 + 108 + 12 + safeArea.bottom + 16
    }

    // Applies the shared native-sheet presentation settings for the lookup sheet.
    func configureSurfaceSheetPresentation(
        _ sheetController: UIViewController,
        preferredHeight: @escaping () -> CGFloat
    ) {
        sheetController.modalPresentationStyle = .pageSheet
        sheetController.presentationController?.delegate = self

        guard let sheetPresentationController = sheetController.sheetPresentationController else {
            return
        }

        if #available(iOS 16.0, *) {
            let fittedDetentIdentifier = UISheetPresentationController.Detent.Identifier("surfaceFitted")
            let fittedDetent = UISheetPresentationController.Detent.custom(identifier: fittedDetentIdentifier) { context in
                // Cap at half the available screen height so the sheet never dominates the reading surface.
                let halfScreen = context.maximumDetentValue * 0.5
                return min(preferredHeight(), halfScreen)
            }
            sheetPresentationController.detents = [fittedDetent, .medium(), .large()]
            sheetPresentationController.selectedDetentIdentifier = fittedDetentIdentifier
            sheetPresentationController.largestUndimmedDetentIdentifier = .large
        } else {
            sheetPresentationController.detents = [.medium()]
            sheetPresentationController.largestUndimmedDetentIdentifier = .medium
        }

        sheetPresentationController.prefersGrabberVisible = false
    }
}
