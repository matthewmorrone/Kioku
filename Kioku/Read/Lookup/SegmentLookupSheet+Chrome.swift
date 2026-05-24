import UIKit

extension SegmentLookupSheet {
    // Applies the shared native-sheet presentation settings for the lookup sheet. The sheet
    // uses UIKit's built-in `.medium()` detent so its height is stable across the entire
    // lifetime of one presentation — no measure-and-resize churn while async dictionary data
    // arrives, which previously moved the merge/split buttons under the user's finger.
    // Content that exceeds the medium height clips at the action menu rather than expanding
    // the sheet.
    func configureSurfaceSheetPresentation(_ sheetController: UIViewController) {
        sheetController.modalPresentationStyle = .pageSheet

        guard let sheetPresentationController = sheetController.sheetPresentationController else {
            return
        }

        // sheetPresentationController exists before presentation; delegate set here is reliable.
        // presentationController is nil before present() is called so setting delegate there is a no-op.
        sheetPresentationController.delegate = self

        sheetPresentationController.detents = [.medium()]
        sheetPresentationController.largestUndimmedDetentIdentifier = .medium
        sheetPresentationController.prefersGrabberVisible = false
    }
}
