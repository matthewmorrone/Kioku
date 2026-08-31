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
        let capturedSheetLemmaInfoByReadingProvider = self.sheetLemmaInfoByReadingProvider
        let capturedSheetDictionaryEntryProvider = self.sheetDictionaryEntryProvider
        let capturedSheetIsSavedProvider = self.sheetIsSavedProvider
        let capturedSheetIsSavedElsewhereProvider = self.sheetIsSavedElsewhereProvider
        let capturedSheetSaveToggle = self.sheetSaveToggle
        // Without these two the save button's long-press Save/Learned/Not Learned menu would
        // never appear on the fresh-present path: resetSheetPresentationState nils them during the
        // dismissPopover below, so updateSaveButtonAppearance would read .unmarked and skip the menu.
        let capturedSheetLearnedStateProvider = self.sheetLearnedStateProvider
        let capturedSheetSetLearnedState = self.sheetSetLearnedState
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
            self.sheetLemmaInfoByReadingProvider = capturedSheetLemmaInfoByReadingProvider
            self.sheetDictionaryEntryProvider = capturedSheetDictionaryEntryProvider
            self.sheetIsSavedProvider = capturedSheetIsSavedProvider
            self.sheetIsSavedElsewhereProvider = capturedSheetIsSavedElsewhereProvider
            self.sheetSaveToggle = capturedSheetSaveToggle
            self.sheetLearnedStateProvider = capturedSheetLearnedStateProvider
            self.sheetSetLearnedState = capturedSheetSetLearnedState
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
            // Initial supplemental data refresh runs ASYNC: the sheet presents immediately
            // with whatever the providers haven't filled in yet (empty arrays / nil), and
            // the per-section UI methods (updateMiddleContent etc.) run when the background
            // refresh hops back to main. Visually: tap → sheet animates in instantly → a
            // few hundred ms later the definitions/components populate. The previous
            // synchronous path blocked the present for the full lookup duration (3–7s).
            // We can't call sheetVC.update* here because sheetVC isn't constructed yet;
            // the sheet's own viewDidLoad reads the current* properties at present time,
            // and the async completion below re-runs the update methods once data arrives.

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

                TapDiagnostics.mark("in-place update closure entered")
                // Header text swaps synchronously so the user sees instant visual feedback
                // (the tapped surface in the sheet header) while the dictionary lookups run.
                sheetVC.updateCurrentSurface((
                    surface: updatedSurface,
                    leftNeighborSurface: updatedLeftNeighborSurface,
                    rightNeighborSurface: updatedRightNeighborSurface
                ))
                TapDiagnostics.mark("updateCurrentSurface done (synchronous header update)")
                // Heavy lookups run on a background queue. When they complete, hop back to
                // main and refresh the rest of the sheet.
                self.refreshSheetSupplementalDataAsync { [weak sheetVC] in
                    guard let sheetVC else { return }
                    TapDiagnostics.mark("async refresh complete, applying to sheet UI")
                    sheetVC.updateReadingFurigana()
                    sheetVC.updateLemmaChain()
                    sheetVC.updateMiddleContent()
                    sheetVC.updateSaveButtonAppearance()
                    sheetVC.updateOpenDetailButtonAppearance()
                    TapDiagnostics.mark("sheet UI updates applied")
                    TapDiagnostics.endTap("in-place update fully settled")
                }
                TapDiagnostics.mark("in-place update closure returning (refresh continues async)")
            }

            self.configureSurfaceSheetPresentation(sheetVC)
            presenter.present(sheetVC, animated: true)
            self.presentedSheetController = sheetVC

            // Kick off the supplemental refresh AFTER present() so the sheet starts
            // animating in immediately — the user sees motion ~16ms after the tap instead
            // of waiting for dictionary work to finish. When the providers complete, the
            // sheet's update* methods re-populate the dynamic sections.
            self.refreshSheetSupplementalDataAsync { [weak sheetVC] in
                guard let sheetVC else { return }
                TapDiagnostics.mark("fresh-present: async refresh complete, applying to sheet UI")
                sheetVC.updateReadingFurigana()
                sheetVC.updateLemmaChain()
                sheetVC.updateMiddleContent()
                sheetVC.updateSaveButtonAppearance()
                sheetVC.updateOpenDetailButtonAppearance()
                TapDiagnostics.mark("fresh-present: sheet UI updates applied")
                TapDiagnostics.endTap("fresh-present fully settled")
            }
        }
    }

    // Clears all sheet-specific provider closures and cached data so a new segment can be configured cleanly.
    private func resetSheetPresentationState() {
        isPreparingSheetDismissal = false
        onWillDismiss = nil
        onSheetSelectPrevious = nil
        onSheetSelectNext = nil
        onReadingSelected = nil
        onReadingReset = nil
        sheetReadingsProvider = nil
        sheetSublatticeProvider = nil
        segmentRangeProvider = nil
        sheetLexiconDebugProvider = nil
        sheetFrequencyProvider = nil
        sheetLemmaInfoProvider = nil
        sheetLemmaInfoByReadingProvider = nil
        activeReadingOverrideProvider = nil
        pathSegmentFrequencyProvider = nil
        sheetDictionaryEntryProvider = nil
        sheetIsSavedProvider = nil
        sheetIsSavedElsewhereProvider = nil
        sheetSaveToggle = nil
        sheetLearnedStateProvider = nil
        sheetSetLearnedState = nil
        sheetOpenWordDetail = nil
        sheetWordComponentsProvider = nil
        sheetCompoundComponentsProvider = nil
        currentSheetCompoundComponents = []
        // Note: onCompoundComponentTapped is intentionally NOT reset — it's installed once by
        // ReadView and represents how the app drills into a compound component, regardless of
        // which segment is currently presented.
        currentSheetUniqueReadings = []
        currentSheetSublatticeEdges = []
        currentSheetLexiconDebugInfo = ""
        currentSheetFrequencyByReading = nil
        currentSheetLemmaInfo = nil
        currentSheetLemmaInfoByReading = [:]
        currentSheetDictionaryEntry = nil
        currentSheetWordComponents = []
        currentSheetCompoundComponents = []
        updatePresentedSheetSelection = nil
    }

    // Dismisses the currently presented action sheet if one is active.
    // Not private: also called (trailing-closure syntax) from dismissPopover in
    // SegmentLookupSheet.swift.
    func dismissSheet(completion: (() -> Void)? = nil) {
        guard let presentedSheetController, hasActivePresentedSheetController else {
            TapDiagnostics.mark("dismissSheet: fast bail (no active presentedSheetController)")
            self.presentedSheetController = nil
            resetSheetPresentationState()
            completion?()
            return
        }

        if isPreparingSheetDismissal == false, let onWillDismiss {
            TapDiagnostics.mark("dismissSheet: SLOW PATH — deferring to onWillDismiss")
            isPreparingSheetDismissal = true
            onWillDismiss { [weak self] in
                self?.dismissSheet(completion: completion)
            }
            return
        }

        TapDiagnostics.mark("dismissSheet: SLOW PATH — calling presentedSheetController.dismiss(animated: true)")
        presentedSheetController.dismiss(animated: true) { [weak self] in
            guard let self else {
                completion?()
                return
            }

            self.presentedSheetController = nil
            self.resetSheetPresentationState()
            completion?()
        }
    }

    // Intercepts system-initiated sheet dismissal so the onWillDismiss hook runs before the sheet disappears.
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        guard presentedSheetController === presentationController.presentedViewController else {
            return true
        }

        guard isPreparingSheetDismissal == false, let onWillDismiss else {
            return true
        }

        isPreparingSheetDismissal = true
        onWillDismiss { [weak self] in
            self?.presentedSheetController?.dismiss(animated: true)
        }
        return false
    }

    // Clears tracked presentation references when users dismiss controllers interactively.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentedController === presentationController.presentedViewController {
            presentedController = nil
            fireOnDismissIfNeeded()
        }

        if presentedSheetController === presentationController.presentedViewController {
            presentedSheetController = nil
            resetSheetPresentationState()
            fireOnDismissIfNeeded()
        } else if updatePresentedSheetSelection != nil {
            presentedSheetController = nil
            resetSheetPresentationState()
            fireOnDismissIfNeeded()
        }
    }

    // Keeps popover style in compact environments so segment-anchored callouts retain the pointer arrow.
    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        return .none
    }

    // Computes a bounded content size for the star/word/definition/arrow row. Content-hugging:
    // a short word + short definition doesn't leave dead space, while a long definition wraps
    // to multiple lines once the row hits maxContentWidth rather than growing unbounded.
    // Not private: called from reallyPresentPopover / updatePresentedPopoverContent in
    // SegmentLookupSheet.swift.
    func preferredPopoverSize(
        for definition: String,
        word: String,
        horizontalInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        interItemSpacing: CGFloat,
        actionButtonWidth: CGFloat,
        actionButtonHeight: CGFloat,
        minWordTapWidth: CGFloat
    ) -> CGSize {
        let minContentWidth: CGFloat = 120
        let maxContentWidth: CGFloat = 320
        let definitionFont = UIFont.systemFont(ofSize: 16)
        let wordFont = UIFont.systemFont(ofSize: 17, weight: .semibold)

        let wordMeasurementLabel = UILabel()
        wordMeasurementLabel.font = wordFont
        wordMeasurementLabel.text = word
        // Must match wordButton's own greaterThanOrEqualToConstant(minWordTapWidth) constraint —
        // otherwise a short word (single kanji) is measured narrower than the button actually
        // renders, under-sizing the popover the same way the missing font attribute once did.
        let wordWidth = max(ceil(wordMeasurementLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ).width), minWordTapWidth)

        // Fixed-width elements: left/right insets, star, word, arrow, and the two inter-item
        // gaps between (star, word) and (word, definition) — definition's own leading gap to
        // the arrow is accounted for separately below.
        let fixedWidth = (horizontalInset * 2) + actionButtonWidth + interItemSpacing
            + wordWidth + interItemSpacing + interItemSpacing + actionButtonWidth

        let definitionMeasurementLabel = UILabel()
        definitionMeasurementLabel.numberOfLines = 0
        definitionMeasurementLabel.font = definitionFont
        definitionMeasurementLabel.text = definition

        let unconstrainedDefinitionSize = definitionMeasurementLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )

        let desiredContentWidth = ceil(unconstrainedDefinitionSize.width) + fixedWidth
        let constrainedContentWidth = min(max(desiredContentWidth, minContentWidth), maxContentWidth)
        let constrainedDefinitionWidth = constrainedContentWidth - fixedWidth
        let constrainedDefinitionSize = definitionMeasurementLabel.sizeThatFits(
            CGSize(width: max(constrainedDefinitionWidth, 1), height: CGFloat.greatestFiniteMagnitude)
        )

        let contentTextHeight = max(ceil(constrainedDefinitionSize.height), ceil(wordMeasurementLabel.sizeThatFits(
            CGSize(width: wordWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height))
        let contentHeight = max(contentTextHeight, actionButtonHeight) + topInset + bottomInset
        return CGSize(width: constrainedContentWidth, height: max(56, min(contentHeight, 260)))
    }

    // Resolves the active screen bounds without relying on deprecated global UIScreen access.
    func activeScreenBounds() -> CGRect {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return CGRect(x: 0, y: 0, width: 390, height: 844)
        }

        return windowScene.screen.bounds
    }

    // Resolves the top-most view controller so popovers present from the active screen context.
    func topPresentingController() -> UIViewController? {
        guard
            let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else {
            return nil
        }

        var topController = rootViewController
        while let presentedController = topController.presentedViewController {
            topController = presentedController
        }

        return topController
    }

    // Formats one dictionary sense as "pos — gloss1; gloss2" for compact inline display.
    func formatSense(_ sense: DictionaryEntrySense) -> String {
        var parts: [String] = []
        if let pos = sense.pos, pos.isEmpty == false { parts.append(JMdictTagExpander.expand(pos)) }
        parts.append(sense.glosses.joined(separator: "; "))
        return parts.joined(separator: " — ")
    }
}
