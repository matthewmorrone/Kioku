import UIKit

// Presents a native UIKit popover anchored to tapped segment rects in the read-mode text view.
final class SegmentLookupSheet: NSObject, UIPopoverPresentationControllerDelegate, UIAdaptivePresentationControllerDelegate, UISheetPresentationControllerDelegate {
    static let shared = SegmentLookupSheet()
    // Key for retaining the tap handler via associated objects (gesture recognizer holds weak ref).
    static var tapHandlerKey: UInt8 = 0
    // Key for retaining the speech synthesizer so it lives long enough to finish speaking.
    static var speechSynthesizerKey: UInt8 = 0

    private weak var presentedController: UIViewController?
    weak var presentedSheetController: UIViewController?
    private var isPreparingSheetDismissal = false
    var onDismiss: (() -> Void)?
    var onWillDismiss: ((@escaping () -> Void) -> Void)?
    var onReadingSelected: ((String) -> Void)?
    // Called when the user taps the reset button to clear the current reading override.
    var onReadingReset: (() -> Void)?
    var onSheetSelectPrevious: (() -> Void)?
    var onSheetSelectNext: (() -> Void)?
    var sheetReadingsProvider: (() -> [String])?
    var sheetSublatticeProvider: (() -> [LatticeEdge])?
    var segmentRangeProvider: (() -> NSRange?)?
    var sheetLexiconDebugProvider: (() -> String)?
    var sheetFrequencyProvider: (() -> [String: FrequencyData]?)?
    // Provides lemma and inflection chain when the current surface is an inflected form distinct from its base.
    var sheetLemmaInfoProvider: (() -> (lemma: String, chain: [String])?)?
    // Returns the currently persisted reading override for the selected segment, if any.
    var activeReadingOverrideProvider: (() -> String?)?
    // Looks up frequency data for any surface in the note — used to annotate sublattice paths.
    var pathSegmentFrequencyProvider: ((String) -> [String: FrequencyData]?)?
    // Provides the minimal dictionary entry needed to render visible senses for the current segment.
    var sheetDictionaryEntryProvider: (() -> DictionaryEntry?)?
    var currentSheetDictionaryEntry: DictionaryEntry? = nil
    // Returns true when the current segment's resolved lemma is already saved.
    var sheetIsSavedProvider: (() -> Bool)?
    // Toggles the saved state for the current segment's resolved lemma.
    var sheetSaveToggle: (() -> Void)?
    // Opens the word detail screen for the current segment's resolved lemma.
    var sheetOpenWordDetail: (() -> Void)?
    // Provides tappable word components: (surface, first gloss) pairs.
    var sheetWordComponentsProvider: (() -> [(surface: String, gloss: String?)]?)?
    var currentSheetWordComponents: [(surface: String, gloss: String?)] = []
    var currentSheetUniqueReadings: [String] = []
    var currentSheetSublatticeEdges: [LatticeEdge] = []
    var currentSheetLexiconDebugInfo: String = ""
    var currentSheetFrequencyByReading: [String: FrequencyData]? = nil
    var currentSheetLemmaInfo: (lemma: String, chain: [String])? = nil
    var updatePresentedSheetSelection: ((
        String,
        String?,
        String?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> [String])?,
        (() -> [LatticeEdge])?,
        (() -> NSRange?)?,
        (() -> String)?,
        (() -> [String: FrequencyData]?)?,
        (() -> Void)?
    ) -> Void)?

    // Prevents external construction so a single presenter coordinates popover lifecycle.
    private override init() {
        super.init()
    }

    private var hasActivePresentedSheetController: Bool {
        guard let presentedSheetController else {
            return false
        }

        return presentedSheetController.isBeingDismissed == false
            && (presentedSheetController.presentingViewController != nil || presentedSheetController.viewIfLoaded?.window != nil)
    }

    // Presents the current definition in a UIKit popover anchored to the tapped segment rectangle.
    func presentPopover(
        definition: String,
        surface: String,
        leftNeighborSurface: String?,
        rightNeighborSurface: String?,
        onMergeLeft: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onMergeRight: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onSplitApply: ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onDismiss: (() -> Void)? = nil,
        sourceView: UIView,
        sourceRect: CGRect
    ) {
        dismissPopover(notifyDismissal: false)
        self.onDismiss = onDismiss

        guard let presentingController = topPresentingController() else {
            return
        }

        let currentSurface = surface

        let viewController = UIViewController()
        viewController.view.backgroundColor = .systemBackground
        let horizontalInset: CGFloat = 10
        let topInset: CGFloat = 4
        let bottomInset: CGFloat = 8
        let interItemSpacing: CGFloat = 8
        let actionButtonWidth: CGFloat = 18
        let actionButtonHeight: CGFloat = 18

        let definitionLabel = UILabel()
        definitionLabel.translatesAutoresizingMaskIntoConstraints = false
        definitionLabel.numberOfLines = 0
        definitionLabel.textColor = .label
        definitionLabel.font = .systemFont(ofSize: 16)
        definitionLabel.text = definition

        let detailsButton = UIButton(type: .system)
        detailsButton.translatesAutoresizingMaskIntoConstraints = false
        detailsButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        detailsButton.tintColor = .secondaryLabel
        detailsButton.contentVerticalAlignment = .center
        detailsButton.contentHorizontalAlignment = .center
        detailsButton.addAction(
            UIAction { [weak self] _ in
                guard let self else {
                    return
                }

                self.presentSurfaceSheet(
                    surface: currentSurface,
                    leftNeighborSurface: leftNeighborSurface,
                    rightNeighborSurface: rightNeighborSurface,
                    onSelectPrevious: nil,
                    onSelectNext: nil,
                    onMergeLeft: onMergeLeft,
                    onMergeRight: onMergeRight,
                    onSplitApply: onSplitApply,
                    sheetReadingsProvider: sheetReadingsProvider,
                    sheetSublatticeProvider: sheetSublatticeProvider,
                    segmentRangeProvider: segmentRangeProvider,
                    sheetLexiconDebugProvider: sheetLexiconDebugProvider,
                    onDismiss: onDismiss
                )
            },
            for: .touchUpInside
        )

        viewController.view.addSubview(definitionLabel)
        viewController.view.addSubview(detailsButton)
        NSLayoutConstraint.activate([
            definitionLabel.topAnchor.constraint(equalTo: viewController.view.topAnchor, constant: topInset),
            definitionLabel.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor, constant: horizontalInset),
            definitionLabel.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor, constant: -bottomInset),

            detailsButton.leadingAnchor.constraint(equalTo: definitionLabel.trailingAnchor, constant: interItemSpacing),
            detailsButton.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor, constant: -horizontalInset),
            detailsButton.centerYAnchor.constraint(equalTo: definitionLabel.centerYAnchor),
            detailsButton.widthAnchor.constraint(equalToConstant: actionButtonWidth),
            detailsButton.heightAnchor.constraint(equalToConstant: actionButtonHeight),
        ])

        viewController.modalPresentationStyle = .popover
        viewController.preferredContentSize = preferredPopoverSize(
            for: definition,
            horizontalInset: horizontalInset,
            topInset: topInset,
            bottomInset: bottomInset,
            interItemSpacing: interItemSpacing,
            actionButtonWidth: actionButtonWidth,
            actionButtonHeight: actionButtonHeight
        )

        guard let popoverPresentationController = viewController.popoverPresentationController else {
            return
        }

        popoverPresentationController.delegate = self
        popoverPresentationController.sourceView = sourceView
        popoverPresentationController.sourceRect = sourceRect
        popoverPresentationController.permittedArrowDirections = [.up, .down]

        presentingController.present(viewController, animated: true)
        presentedController = viewController
    }

    // Presents the segment action sheet directly without first showing a popover.
    func presentSheet(
        surface: String,
        leftNeighborSurface: String?,
        rightNeighborSurface: String?,
        onSelectPrevious: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onSelectNext: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onMergeLeft: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onMergeRight: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        onSplitApply: ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)? = nil,
        sheetReadingsProvider: (() -> [String])? = nil,
        sheetSublatticeProvider: (() -> [LatticeEdge])? = nil,
        segmentRangeProvider: (() -> NSRange?)? = nil,
        sheetLexiconDebugProvider: (() -> String)? = nil,
        sheetFrequencyProvider: (() -> [String: FrequencyData]?)? = nil,
        sheetLemmaInfoProvider: (() -> (lemma: String, chain: [String])?)? = nil,
        onReadingSelected: ((String) -> Void)? = nil,
        onReadingReset: (() -> Void)? = nil,
        activeReadingOverrideProvider: (() -> String?)? = nil,
        pathSegmentFrequencyProvider: ((String) -> [String: FrequencyData]?)? = nil,
        sheetDictionaryEntryProvider: (() -> DictionaryEntry?)? = nil,
        sheetIsSavedProvider: (() -> Bool)? = nil,
        sheetSaveToggle: (() -> Void)? = nil,
        sheetOpenWordDetail: (() -> Void)? = nil,
        sheetWordComponentsProvider: (() -> [(surface: String, gloss: String?)]?)? = nil,
        onWillDismiss: ((@escaping () -> Void) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        if hasActivePresentedSheetController == false, updatePresentedSheetSelection != nil {
            presentedSheetController = nil
            isPreparingSheetDismissal = false
            updatePresentedSheetSelection = nil
        }

        // Always update the reading callbacks so re-taps on a different segment get the right closures.
        self.onWillDismiss = onWillDismiss
        self.onReadingSelected = onReadingSelected
        self.onReadingReset = onReadingReset
        self.activeReadingOverrideProvider = activeReadingOverrideProvider
        self.pathSegmentFrequencyProvider = pathSegmentFrequencyProvider
        self.sheetLemmaInfoProvider = sheetLemmaInfoProvider
        self.sheetDictionaryEntryProvider = sheetDictionaryEntryProvider
        self.sheetIsSavedProvider = sheetIsSavedProvider
        self.sheetSaveToggle = sheetSaveToggle
        self.sheetOpenWordDetail = sheetOpenWordDetail
        self.sheetWordComponentsProvider = sheetWordComponentsProvider
        if let updatePresentedSheetSelection, hasActivePresentedSheetController {
            self.onDismiss = onDismiss
            self.onWillDismiss = onWillDismiss
            updatePresentedSheetSelection(
                surface,
                leftNeighborSurface,
                rightNeighborSurface,
                onSelectPrevious,
                onSelectNext,
                onMergeLeft,
                onMergeRight,
                onSplitApply,
                sheetReadingsProvider,
                sheetSublatticeProvider,
                segmentRangeProvider,
                sheetLexiconDebugProvider,
                sheetFrequencyProvider,
                onDismiss
            )
            return
        }

        self.onDismiss = onDismiss
        presentSurfaceSheet(
            surface: surface,
            leftNeighborSurface: leftNeighborSurface,
            rightNeighborSurface: rightNeighborSurface,
            onSelectPrevious: onSelectPrevious,
            onSelectNext: onSelectNext,
            onMergeLeft: onMergeLeft,
            onMergeRight: onMergeRight,
            onSplitApply: onSplitApply,
            sheetReadingsProvider: sheetReadingsProvider,
            sheetSublatticeProvider: sheetSublatticeProvider,
            segmentRangeProvider: segmentRangeProvider,
            sheetLexiconDebugProvider: sheetLexiconDebugProvider,
            sheetFrequencyProvider: sheetFrequencyProvider,
            onDismiss: onDismiss
        )
    }

    // Dismisses any active segment presentation (sheet/popover), used when selection clears.
    func dismissPopover(notifyDismissal: Bool = true, completion: (() -> Void)? = nil) {
        dismissSheet { [weak self] in
            guard let self else {
                completion?()
                return
            }

            guard let presentedController else {
                if notifyDismissal {
                    self.fireOnDismissIfNeeded()
                }
                completion?()
                return
            }

            presentedController.dismiss(animated: true) {
                if notifyDismissal {
                    self.fireOnDismissIfNeeded()
                }
                completion?()
            }
            self.presentedController = nil
        }
    }

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
        activeReadingOverrideProvider = nil
        pathSegmentFrequencyProvider = nil
        sheetDictionaryEntryProvider = nil
        sheetIsSavedProvider = nil
        sheetSaveToggle = nil
        sheetOpenWordDetail = nil
        sheetWordComponentsProvider = nil
        currentSheetUniqueReadings = []
        currentSheetSublatticeEdges = []
        currentSheetLexiconDebugInfo = ""
        currentSheetFrequencyByReading = nil
        currentSheetLemmaInfo = nil
        currentSheetDictionaryEntry = nil
        currentSheetWordComponents = []
        updatePresentedSheetSelection = nil
    }

    // Dismisses the currently presented action sheet if one is active.
    private func dismissSheet(completion: (() -> Void)? = nil) {
        guard let presentedSheetController, hasActivePresentedSheetController else {
            self.presentedSheetController = nil
            resetSheetPresentationState()
            completion?()
            return
        }

        if isPreparingSheetDismissal == false, let onWillDismiss {
            isPreparingSheetDismissal = true
            onWillDismiss { [weak self] in
                self?.dismissSheet(completion: completion)
            }
            return
        }

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

    // Computes a bounded content size for readable multiline definition text and action button affordance.
    private func preferredPopoverSize(
        for definition: String,
        horizontalInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        interItemSpacing: CGFloat,
        actionButtonWidth: CGFloat,
        actionButtonHeight: CGFloat
    ) -> CGSize {
        let minContentWidth: CGFloat = 84
        let maxContentWidth: CGFloat = 320
        let font = UIFont.systemFont(ofSize: 16)

        let measurementLabel = UILabel()
        measurementLabel.numberOfLines = 0
        measurementLabel.font = font
        measurementLabel.text = definition

        let unconstrainedLabelSize = measurementLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )

        let desiredContentWidth = ceil(unconstrainedLabelSize.width) + (horizontalInset * 2) + interItemSpacing + actionButtonWidth
        let constrainedContentWidth = min(max(desiredContentWidth, minContentWidth), maxContentWidth)
        let constrainedTextWidth = constrainedContentWidth - (horizontalInset * 2) - interItemSpacing - actionButtonWidth
        let constrainedLabelSize = measurementLabel.sizeThatFits(
            CGSize(width: constrainedTextWidth, height: CGFloat.greatestFiniteMagnitude)
        )

        let textHeight = ceil(constrainedLabelSize.height)
        let contentHeight = max(textHeight, actionButtonHeight) + topInset + bottomInset
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
