import UIKit

extension SegmentLookupSheet {
    // Presents a bottom sheet that starts at a fitted small detent and can expand to medium.
    // All interactive sheet state lives in SurfaceSheetViewController; this method wires
    // the coordinator back-reference, installs the updatePresentedSheetSelection callback,
    // and configures sheet presentation detents.
    func presentSurfaceSheet(
        surface: String,
        leftNeighborSurface: String?,
        rightNeighborSurface: String?,
        onSelectPrevious: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onSelectNext: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onMergeLeft: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onMergeRight: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onSplitApply: ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        sheetReadingsProvider: (() -> [String])?,
        sheetSublatticeProvider: (() -> [LatticeEdge])?,
        segmentRangeProvider: (() -> NSRange?)?,
        sheetLexiconDebugProvider: (() -> String)?,
        sheetFrequencyProvider: (() -> [String: FrequencyData]?)? = nil,
        onDismiss: (() -> Void)?
    ) {
        // Capture reading/save callbacks before dismissPopover, since dismissSheet clears them.
        let capturedOnReadingSelected = self.onReadingSelected
        let capturedPathSegmentFrequencyProvider = self.pathSegmentFrequencyProvider
        let capturedSheetLemmaInfoProvider = self.sheetLemmaInfoProvider
        let capturedSheetDictionaryEntryProvider = self.sheetDictionaryEntryProvider
        let capturedSheetIsSavedProvider = self.sheetIsSavedProvider
        let capturedSheetSaveToggle = self.sheetSaveToggle
        let capturedSheetOpenWordDetail = self.sheetOpenWordDetail
        let capturedSheetWordComponentsProvider = self.sheetWordComponentsProvider
        let capturedSheetCompoundComponentsProvider = self.sheetCompoundComponentsProvider
        let capturedActiveReadingOverrideProvider = self.activeReadingOverrideProvider
        let capturedOnReadingReset = self.onReadingReset
        let capturedOnWillDismiss = self.onWillDismiss

        dismissPopover(notifyDismissal: false) { [weak self] in
            guard let self, let presenter = self.topPresentingController() else { return }

            self.onDismiss = onDismiss
            self.onWillDismiss = capturedOnWillDismiss
            self.onReadingSelected = capturedOnReadingSelected
            self.onReadingReset = capturedOnReadingReset
            self.pathSegmentFrequencyProvider = capturedPathSegmentFrequencyProvider
            self.sheetLemmaInfoProvider = capturedSheetLemmaInfoProvider
            self.sheetDictionaryEntryProvider = capturedSheetDictionaryEntryProvider
            self.sheetIsSavedProvider = capturedSheetIsSavedProvider
            self.sheetSaveToggle = capturedSheetSaveToggle
            self.sheetOpenWordDetail = capturedSheetOpenWordDetail
            self.sheetWordComponentsProvider = capturedSheetWordComponentsProvider
            self.sheetCompoundComponentsProvider = capturedSheetCompoundComponentsProvider
            self.activeReadingOverrideProvider = capturedActiveReadingOverrideProvider
            self.onSheetSelectPrevious = nil
            self.onSheetSelectNext = nil
            self.sheetReadingsProvider = sheetReadingsProvider
            self.sheetSublatticeProvider = sheetSublatticeProvider
            self.segmentRangeProvider = segmentRangeProvider
            self.sheetLexiconDebugProvider = sheetLexiconDebugProvider
            self.sheetFrequencyProvider = sheetFrequencyProvider
            self.refreshSheetSupplementalData()

            let sheetVC = SurfaceSheetViewController(
                surface: surface,
                leftNeighborSurface: leftNeighborSurface,
                rightNeighborSurface: rightNeighborSurface,
                onSelectPrevious: onSelectPrevious,
                onSelectNext: onSelectNext,
                onMergeLeft: onMergeLeft,
                onMergeRight: onMergeRight,
                onSplitApply: onSplitApply
            )
            sheetVC.sheet = self

            self.onSheetSelectNext = { [weak sheetVC] in
                guard let sheetVC, sheetVC.isSplitEditorVisible == false,
                      let outcome = sheetVC.currentOnSelectNext?() else { return }
                sheetVC.updateCurrentSurface(outcome)
                sheetVC.updateSheetPreferredHeight(animated: false)
                self.refreshSheetSupplementalData()
                sheetVC.updateReadingFurigana()
                sheetVC.updateLemmaChain()
                sheetVC.updateMiddleContent()
                sheetVC.updateSaveButtonAppearance()
                sheetVC.updateOpenDetailButtonAppearance()
            }

            self.onSheetSelectPrevious = { [weak sheetVC] in
                guard let sheetVC, sheetVC.isSplitEditorVisible == false,
                      let outcome = sheetVC.currentOnSelectPrevious?() else { return }
                sheetVC.updateCurrentSurface(outcome)
                sheetVC.updateSheetPreferredHeight(animated: false)
                self.refreshSheetSupplementalData()
                sheetVC.updateReadingFurigana()
                sheetVC.updateLemmaChain()
                sheetVC.updateMiddleContent()
                sheetVC.updateSaveButtonAppearance()
                sheetVC.updateOpenDetailButtonAppearance()
            }

            self.updatePresentedSheetSelection = { [weak sheetVC] (
                updatedSurface,
                updatedLeftNeighborSurface,
                updatedRightNeighborSurface,
                updatedOnSelectPrevious,
                updatedOnSelectNext,
                updatedOnMergeLeft,
                updatedOnMergeRight,
                updatedOnSplitApply,
                updatedSheetReadingsProvider,
                updatedSheetSublatticeProvider,
                updatedSegmentRangeProvider,
                updatedSheetLexiconDebugProvider,
                updatedSheetFrequencyProvider,
                updatedOnDismiss
            ) in
                guard let sheetVC else { return }
                sheetVC.currentOnSelectPrevious = updatedOnSelectPrevious
                sheetVC.currentOnSelectNext = updatedOnSelectNext
                sheetVC.currentOnMergeLeft = updatedOnMergeLeft
                sheetVC.currentOnMergeRight = updatedOnMergeRight
                sheetVC.currentOnSplitApply = updatedOnSplitApply
                self.sheetReadingsProvider = updatedSheetReadingsProvider
                self.sheetSublatticeProvider = updatedSheetSublatticeProvider
                self.segmentRangeProvider = updatedSegmentRangeProvider
                self.sheetLexiconDebugProvider = updatedSheetLexiconDebugProvider
                self.sheetFrequencyProvider = updatedSheetFrequencyProvider
                self.onDismiss = updatedOnDismiss

                if sheetVC.isSplitEditorVisible {
                    sheetVC.setSplitEditorVisible(false)
                }

                sheetVC.updateCurrentSurface((
                    surface: updatedSurface,
                    leftNeighborSurface: updatedLeftNeighborSurface,
                    rightNeighborSurface: updatedRightNeighborSurface
                ))
                sheetVC.updateSheetPreferredHeight(animated: true)
                self.refreshSheetSupplementalData()
                sheetVC.updateReadingFurigana()
                sheetVC.updateLemmaChain()
                sheetVC.updateMiddleContent()
                sheetVC.updateSaveButtonAppearance()
                sheetVC.updateOpenDetailButtonAppearance()
            }

            // Views aren't built yet (viewDidLoad fires on present); use fallback height.
            // viewDidLoad recomputes currentSheetPreferredHeight once views exist.
            sheetVC.currentSheetPreferredHeight = 400
            self.configureSurfaceSheetPresentation(sheetVC) {
                sheetVC.currentSheetPreferredHeight
            }
            presenter.present(sheetVC, animated: true)
            self.presentedSheetController = sheetVC
        }
    }
}
