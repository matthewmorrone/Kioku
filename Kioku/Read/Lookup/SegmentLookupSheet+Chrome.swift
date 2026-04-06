import UIKit

extension SegmentLookupSheet {
    // Returns the fixed chrome height outside the middle content and optional split panel.
    func surfaceSheetBaseChromeHeight(headerHeight: CGFloat, safeArea: UIEdgeInsets) -> CGFloat {
        20 + safeArea.top + headerHeight + 8 + 16 + 108 + 12 + safeArea.bottom + 16
    }

    // Applies the shared native-sheet presentation settings for the lookup sheet.
    func configureSurfaceSheetPresentation(
        _ sheetController: UIViewController,
        preferredHeight: @escaping () -> CGFloat
    ) {
        sheetController.modalPresentationStyle = .pageSheet

        guard let sheetPresentationController = sheetController.sheetPresentationController else {
            return
        }

        // sheetPresentationController exists before presentation; delegate set here is reliable.
        // presentationController is nil before present() is called so setting delegate there is a no-op.
        sheetPresentationController.delegate = self

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

        sheetPresentationController.prefersGrabberVisible = true
    }
}
