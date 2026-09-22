import UIKit

extension SegmentLookupSheet {
    // Applies the shared native-sheet presentation settings for the lookup sheet. The sheet uses
    // a single content-fitted detent (SurfaceSheetViewController.contentDetent()) sized to
    // whatever is actually on screen, instead of a fixed `.medium()` that leaves dead space below
    // short entries and clips long ones. This only stays stable because presentSurfaceSheet waits
    // for the dictionary lookup to resolve before calling this — the sheet is built and presented
    // once, against final content, rather than presented empty and resized as data streams in
    // (which is what previously moved the merge/split buttons under the user's finger).
    func configureSurfaceSheetPresentation(_ sheetController: SurfaceSheetViewController) {
        sheetController.modalPresentationStyle = .pageSheet

        guard let sheetPresentationController = sheetController.sheetPresentationController else {
            return
        }

        // sheetPresentationController exists before presentation; delegate set here is reliable.
        // presentationController is nil before present() is called so setting delegate there is a no-op.
        sheetPresentationController.delegate = self

        sheetPresentationController.detents = [sheetController.contentDetent()]
        sheetPresentationController.largestUndimmedDetentIdentifier = sheetController.contentDetentIdentifier
        sheetPresentationController.prefersGrabberVisible = false
    }
}
