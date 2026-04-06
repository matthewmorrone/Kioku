import UIKit

// Bottom sheet that renders segment lookup, merge/split actions, and reading navigation.
// Extracted from SegmentLookupSheet.presentSurfaceSheet so the local-variable/closure tangle
// lives as typed properties and named methods on a proper UIViewController subclass.
// UI construction and action wiring live in SurfaceSheetViewController+Build.swift.
final class SurfaceSheetViewController: UIViewController {

    // MARK: - Delegate

    // Back-reference to the coordinator that manages presentation and shared supplemental data.
    weak var sheet: SegmentLookupSheet?

    // MARK: - Segment state

    var currentSurface: String
    var currentLeftNeighborSurface: String?
    var currentRightNeighborSurface: String?
    var currentOnSelectPrevious: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?
    var currentOnSelectNext: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?
    var currentOnMergeLeft: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?
    var currentOnMergeRight: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?
    var currentOnSplitApply: ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?

    // MARK: - Reading state

    var currentReadingIndex = 0
    var currentReadings: [String] = []
    var customReading: String?
    var allowsCustomReading = false

    // MARK: - Split state

    var leftSplitValue = ""
    var rightSplitValue = ""
    var splitEntryLeftValue = ""
    var splitEntryRightValue = ""
    var isSplitEditorVisible = false
    var currentSheetPreferredHeight: CGFloat = 0

    // MARK: - UI components (set up in buildHeader/buildSplitPanel/buildActionMenu/buildMiddleContent)

    var headerStack: UIStackView!
    var headerRow: UIStackView!
    var lemmaLabel: UILabel!
    var headerContainer: UIView!
    var prevReadingButton: UIButton!
    var nextReadingButton: UIButton!
    var splitPanelContainer: UIStackView!
    var splitPanelCollapsedConstraint: NSLayoutConstraint!
    var leftInput: UITextField!
    var rightInput: UITextField!
    var leftInputTapButton: UIButton!
    var rightInputTapButton: UIButton!
    var splitButton: UIButton!
    var cancelSplitButton: UIButton!
    var applySplitButton: UIButton!
    var mergeLeftButton: UIButton!
    var mergeRightButton: UIButton!
    var saveButton: UIButton!
    var openDetailButton: UIButton!
    var middleContentStack: UIStackView!
    var wordActionsStack: UIStackView!
    var actionMenuContainer: UIView!

    // MARK: - Init

    // Initializes with all navigation/merge/split callbacks for the initial segment.
    init(
        surface: String,
        leftNeighborSurface: String?,
        rightNeighborSurface: String?,
        onSelectPrevious: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?,
        onSelectNext: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?,
        onMergeLeft: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?,
        onMergeRight: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?,
        onSplitApply: ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)?)?
    ) {
        self.currentSurface = surface
        self.currentLeftNeighborSurface = leftNeighborSurface
        self.currentRightNeighborSurface = rightNeighborSurface
        self.currentOnSelectPrevious = onSelectPrevious
        self.currentOnSelectNext = onSelectNext
        self.currentOnMergeLeft = onMergeLeft
        self.currentOnMergeRight = onMergeRight
        self.currentOnSplitApply = onSplitApply
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - View lifecycle

    // Builds the sheet UI and wires all button actions. Must be called after `sheet` is set.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Keeps content clear of the grabber area so the title is never clipped.
        additionalSafeAreaInsets.top = 20

        buildHeader()
        buildSplitPanel()
        buildActionMenu()
        buildMiddleContent()
        layoutRootSubviews()
        wireActions()

        updateMiddleContent()
        updateOpenDetailButtonAppearance()
        updateReadingFurigana()
        updateLemmaChain()
        splitButton.isEnabled = currentSurface.count > 1
        splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
        updateMergeButtonAvailability()
    }

    // MARK: - Reading management

    // Returns the reading that should be displayed in the header right now.
    func displayedReading() -> String? {
        if let customReading { return customReading }
        guard currentReadings.indices.contains(currentReadingIndex) else { return nil }
        return currentReadings[currentReadingIndex]
    }

    // Rebuilds the furigana header to show the reading at the current index.
    func syncFuriganaToCurrentIndex() {
        rebuildHeaderRow(reading: displayedReading())
    }

    // Rebuilds the header row with the given reading (or nil for a blank reading).
    func rebuildHeaderRow(reading: String?) {
        sheet?.rebuildSheetHeaderRow(headerRow, surface: currentSurface, reading: reading)
    }

    // Refreshes reading list, override state, and header display for the current segment.
    // Initializes the selected index from any persisted override so the UI reflects prior choices.
    func updateReadingFurigana() {
        guard let sheet else { return }
        currentReadings = sheet.currentSheetUniqueReadings
        allowsCustomReading = ScriptClassifier.containsKanji(currentSurface)

        let activeOverride = sheet.activeReadingOverrideProvider?()
        if let override = activeOverride, let idx = currentReadings.firstIndex(of: override) {
            currentReadingIndex = idx
            customReading = nil
        } else if allowsCustomReading, let override = activeOverride, currentReadings.contains(override) == false {
            currentReadingIndex = 0
            customReading = override
        } else {
            currentReadingIndex = 0
            customReading = nil
        }
        if currentReadings.indices.contains(currentReadingIndex) == false {
            currentReadingIndex = 0
        }

        syncFuriganaToCurrentIndex()
        updateReadingNavigationButtons()
    }

    // Applies the visible reading choice to the lookup sheet, favoring a custom override when present.
    func applyCurrentReadingSelection() {
        if let customReading {
            sheet?.onReadingSelected?(customReading)
        } else if currentReadings.indices.contains(currentReadingIndex) {
            sheet?.onReadingSelected?(currentReadings[currentReadingIndex])
        }
    }

    // Shows or hides the reading navigation arrows based on how many candidates exist.
    func updateReadingNavigationButtons() {
        let canCycleReadings = currentReadings.count > 1
        prevReadingButton.isHidden = !canCycleReadings
        nextReadingButton.isHidden = !canCycleReadings
        prevReadingButton.isEnabled = canCycleReadings
        nextReadingButton.isEnabled = canCycleReadings
        prevReadingButton.alpha = canCycleReadings ? 1 : 0.45
        nextReadingButton.alpha = canCycleReadings ? 1 : 0.45
    }

    // Updates the lemma label when the surface changes or supplemental data refreshes.
    func updateLemmaChain() {
        let lemma = sheet?.currentSheetLemmaInfo.map { $0.lemma }
        let show = lemma != nil && lemma != currentSurface
        lemmaLabel.text = show ? lemma : nil
        lemmaLabel.isHidden = !show
        syncFuriganaToCurrentIndex()
    }

    // Presents the custom reading alert for the header row tap gesture.
    func presentCustomReadingAlert() {
        guard allowsCustomReading else { return }
        let alert = UIAlertController(title: "Custom Reading", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.displayedReading()
            field.placeholder = "e.g. よむ"
            field.clearButtonMode = .whileEditing
            field.keyboardType = .default
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if sheet?.activeReadingOverrideProvider?() != nil {
            alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
                self?.customReading = nil
                self?.currentReadingIndex = 0
                self?.sheet?.onReadingReset?()
                self?.syncFuriganaToCurrentIndex()
                self?.updateMiddleContent()
            })
        }
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self] _ in
            let entered = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard entered.isEmpty == false else { return }
            self?.customReading = entered
            self?.syncFuriganaToCurrentIndex()
            self?.sheet?.onReadingSelected?(entered)
        })
        present(alert, animated: true)
    }

    // MARK: - Surface / navigation management

    // Applies a merge or split outcome: updates surface, neighbor labels, and button availability.
    func updateCurrentSurface(_ outcome: (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)) {
        currentSurface = outcome.surface
        currentLeftNeighborSurface = outcome.leftNeighborSurface
        currentRightNeighborSurface = outcome.rightNeighborSurface
        // Clear the header reading until the new segment's providers refresh.
        rebuildHeaderRow(reading: nil)
        splitButton.isEnabled = currentSurface.count > 1
        splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
        updateMergeButtonAvailability()
    }

    // Reflects current neighbor availability in merge button enabled state and opacity.
    func updateMergeButtonAvailability() {
        mergeLeftButton.isEnabled = currentLeftNeighborSurface != nil
        mergeLeftButton.alpha = currentLeftNeighborSurface == nil ? 0.45 : 1
        mergeRightButton.isEnabled = currentRightNeighborSurface != nil
        mergeRightButton.alpha = currentRightNeighborSurface == nil ? 0.45 : 1
    }

    // Routes horizontal swipe gestures to segment navigation callbacks on the sheet coordinator.
    @objc func handleSheetSwipe(_ gestureRecognizer: UISwipeGestureRecognizer) {
        switch gestureRecognizer.direction {
        case .left: sheet?.onSheetSelectNext?()
        case .right: sheet?.onSheetSelectPrevious?()
        default: break
        }
    }

    // MARK: - Split management

    // Shows or hides the split editor panel and updates button tint and sheet height.
    func setSplitEditorVisible(_ visible: Bool) {
        isSplitEditorVisible = visible
        splitPanelContainer.isHidden = !visible
        splitPanelCollapsedConstraint.isActive = !visible
        splitButton.tintColor = visible ? .label : .secondaryLabel
        updateSheetPreferredHeight(animated: true)
    }

    // Resets left and right split values to the highest-scoring two-segment sublattice path,
    // falling back to a midpoint split when no two-segment path exists.
    func resetSplitInputs(using outcomeSurface: String) {
        guard let sheet else { return }

        func segmentScore(_ segment: String) -> Double {
            sheet.pathSegmentFrequencyProvider?(segment).flatMap { sheet.normalizedSheetFrequencyScore($0) } ?? 0
        }

        func pathScore(_ path: [String]) -> Double {
            path.map(segmentScore).reduce(0, +) / max(1, Double(path.count))
        }

        let twoPaths = sheet.sublatticeValidPaths(from: sheet.currentSheetSublatticeEdges).filter { $0.count == 2 }
        if let best = twoPaths.max(by: { pathScore($0) < pathScore($1) }) {
            leftSplitValue = best[0]
            rightSplitValue = best[1]
        } else {
            let characters = Array(outcomeSurface)
            if characters.count <= 1 {
                leftSplitValue = outcomeSurface
                rightSplitValue = ""
            } else {
                let midpoint = characters.count / 2
                leftSplitValue = String(characters[0..<midpoint])
                rightSplitValue = String(characters[midpoint..<characters.count])
            }
        }

        leftInput.text = leftSplitValue
        rightInput.text = rightSplitValue
        let isSplitValid = leftSplitValue.isEmpty == false && rightSplitValue.isEmpty == false
        applySplitButton.isEnabled = isSplitValid
        applySplitButton.alpha = applySplitButton.isEnabled ? 1 : 0.5
        leftInputTapButton.isEnabled = rightSplitValue.isEmpty == false
        leftInputTapButton.alpha = leftInputTapButton.isEnabled ? 1 : 0.45
        rightInputTapButton.isEnabled = leftSplitValue.isEmpty == false
        rightInputTapButton.alpha = rightInputTapButton.isEnabled ? 1 : 0.45
    }

    // MARK: - Content and height

    // Delegates middle content rebuild to the sheet coordinator which holds shared data.
    func updateMiddleContent() {
        sheet?.updateMiddleContent(in: middleContentStack)
    }

    // Refreshes the save button icon and tint to reflect the current saved state.
    func updateSaveButtonAppearance() {
        let isSaved = sheet?.sheetIsSavedProvider?() ?? false
        saveButton.setImage(UIImage(systemName: isSaved ? "star.fill" : "star"), for: .normal)
        saveButton.tintColor = isSaved ? .systemYellow : .secondaryLabel
        saveButton.accessibilityLabel = isSaved ? "Unsave" : "Save"
    }

    // Reflects whether the current surface resolved to a dictionary entry that can be opened.
    func updateOpenDetailButtonAppearance() {
        let hasDictionaryEntry = sheet?.currentSheetDictionaryEntry != nil
        openDetailButton.setImage(UIImage(systemName: "text.magnifyingglass"), for: .normal)
        openDetailButton.isEnabled = hasDictionaryEntry
        openDetailButton.alpha = hasDictionaryEntry ? 1 : 0.45
        openDetailButton.tintColor = hasDictionaryEntry ? .systemBlue : .tertiaryLabel
        openDetailButton.backgroundColor = hasDictionaryEntry
            ? UIColor.systemBlue.withAlphaComponent(0.14)
            : .tertiarySystemFill
        openDetailButton.accessibilityLabel = hasDictionaryEntry
            ? "Look Up in Words"
            : "No Dictionary Entry Available"
    }

    // Recalculates and applies the preferred sheet height for the current state.
    func updateSheetPreferredHeight(animated: Bool) {
        _ = animated
        currentSheetPreferredHeight = computePreferredSheetHeight()
        if #available(iOS 16.0, *) {
            sheetPresentationController?.invalidateDetents()
        }
    }

    // Measures actual rendered component sizes to derive the ideal sheet height.
    func computePreferredSheetHeight() -> CGFloat {
        guard let sheet else { return 400 }
        let contentWidth = max(200, sheet.activeScreenBounds().width) - 32
        let middleHeight = ceil(middleContentStack.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
        let splitHeight = ceil(splitPanelContainer.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
        let headerHeight = ceil(headerContainer.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
        let safeArea = view.window?.safeAreaInsets ?? .zero
        let baseChrome = sheet.surfaceSheetBaseChromeHeight(headerHeight: headerHeight, safeArea: safeArea)
        return baseChrome + middleHeight + splitHeight
    }
}
