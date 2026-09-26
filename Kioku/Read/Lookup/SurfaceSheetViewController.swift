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

    var leftSplitValue = "" { didSet { updateSplitCostLabel(); refreshSplitCandidateSelection() } }
    var rightSplitValue = "" { didSet { updateSplitCostLabel(); refreshSplitCandidateSelection() } }
    var splitEntryLeftValue = ""
    var splitEntryRightValue = ""
    var isSplitEditorVisible = false

    // MARK: - UI components (set up in buildHeader/buildSplitPanel/buildActionMenu/buildMiddleContent)

    var headerStack: UIStackView!
    var headerRow: UIStackView!
    var lemmaLabel: UILabel!
    var headerContainer: UIView!
    var prevReadingButton: UIButton!
    var nextReadingButton: UIButton!
    var splitPanelContainer: UIStackView!
    var splitPanelCollapsedConstraint: NSLayoutConstraint!
    // Collapses the definitions area to 0 height while the split editor is open, freeing the vertical
    // room the taller split panel needs within the content-fitted detent.
    var middleContentCollapsedConstraint: NSLayoutConstraint!
    // Identifier for the sheet's single content-fitted detent (see contentDetent()).
    let contentDetentIdentifier = UISheetPresentationController.Detent.Identifier("kioku.content")
    // Height of everything the sheet holds, measured in viewDidLayoutSubviews and read back by
    // the detent resolver. Zero until the first layout pass.
    var measuredContentHeight: CGFloat = 0
    var leftInput: UITextField!
    var rightInput: UITextField!
    var leftInputTapButton: UIButton!
    var rightInputTapButton: UIButton!
    var splitButton: UIButton!
    var cancelSplitButton: UIButton!
    var applySplitButton: UIButton!
    // Shows the segmenter's cost for every cut of the segment (below the [] ↔ [] inputs).
    var splitCostLabel: UILabel?
    // Scroll container for the split readout; lets it scroll instead of clipping when there are more
    // cut rows than the fixed medium detent can show.
    var splitCostScroll: UIScrollView?
    // Horizontally-scrolling row of selectable two-way split candidates (one chip per cut, left to
    // right) — a cut is one tap away instead of nudging the boundary character-by-character.
    // Hidden when there are fewer than two candidates.
    var splitCandidatesScroll: UIScrollView?
    var splitCandidatesRow: UIStackView?
    // Every way to cut the segment in two, left to right, each with the segmenter's cost for the line
    // cut that way (Segmenter.splitCosts; nil while it isn't ready). The one list the readout, the
    // chips and the default pick all read. Chip tag is its index here.
    var splitCandidates: [(path: [String], cost: Int?)] = []
    var mergeLeftButton: UIButton!
    var mergeRightButton: UIButton!
    var saveButton: UIButton!
    var openDetailButton: UIButton!
    var middleContentContainer: UIView!
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
        splitButton.isEnabled = currentSurface.count > 1 && currentOnSplitApply != nil
        splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
        updateMergeButtonAvailability()
    }

    // Measures the content from a real layout pass — the one point where multi-line labels have
    // already wrapped to the sheet's width, so the height covers everything the sheet holds
    // rather than the single-line heights a cold measurement reports. The detent closure only
    // reads `measuredContentHeight`: measuring, or resizing anything, from inside the resolver
    // re-enters layout.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0 else { return }
        let fitted = view.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(fitted - measuredContentHeight) > 0.5 else { return }
        measuredContentHeight = fitted
        // Off this layout pass: invalidateDetents resizes the sheet, which lays out again.
        // The guard above is what stops the second pass from scheduling a third.
        DispatchQueue.main.async { [weak self] in
            self?.invalidateContentDetentIfPresented()
        }
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

    // Rebuilds the header row with the given reading (or nil for a blank reading). Callers include
    // an async supplemental-data-refresh completion that can still be in flight after this
    // controller's view has been dismissed/torn down (e.g. the user tapped through to another
    // word before it finished) — headerRow is an IUO populated at view-load time, so guard rather
    // than force-unwrap a nil outlet into a crash for what's just a stale, ignorable completion.
    func rebuildHeaderRow(reading: String?) {
        guard let headerRow else { return }
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
    // Same async-completion-after-teardown race as rebuildHeaderRow above — guard rather
    // than force-unwrap the IUO outlets into a crash for a stale, ignorable completion.
    func updateReadingNavigationButtons() {
        guard let prevReadingButton, let nextReadingButton else { return }
        let canCycleReadings = currentReadings.count > 1
        prevReadingButton.isHidden = !canCycleReadings
        nextReadingButton.isHidden = !canCycleReadings
        prevReadingButton.isEnabled = canCycleReadings
        nextReadingButton.isEnabled = canCycleReadings
        prevReadingButton.alpha = canCycleReadings ? 1 : 0.45
        nextReadingButton.alpha = canCycleReadings ? 1 : 0.45
    }

    // Repoints currentSheetLemmaInfo and currentSheetDictionaryEntry at whatever lemma owns
    // the currently selected reading. Called by the arrow handlers so cycling between readings
    // (e.g. さわる ↔ ふれる for 触れられない) refreshes the lemma label and the gloss panel to
    // match the linguistically correct lemma for the chosen reading. No-op when the per-reading
    // map is empty (single-reading surface) or doesn't contain an entry for the current reading.
    func syncLemmaAndEntryToCurrentReading() {
        guard let sheet else { return }
        guard currentReadings.indices.contains(currentReadingIndex) else { return }
        let reading = currentReadings[currentReadingIndex]
        guard let info = sheet.currentSheetLemmaInfoByReading[reading] else { return }
        sheet.currentSheetLemmaInfo = (lemma: info.lemma, chain: info.chain)
        if let entry = info.entry {
            sheet.currentSheetDictionaryEntry = entry
        }
    }

    // Updates the lemma label when the surface changes or supplemental data refreshes. The
    // refresh completion can land after this controller's view is torn down (a dictionary
    // download finishing mid-session rebuilds the read resources and re-presents the sheet), so
    // the IUO outlet is guarded like rebuildHeaderRow's rather than trapped on.
    func updateLemmaChain() {
        guard let lemmaLabel else { return }
        let info = sheet?.currentSheetLemmaInfo
        let show = info != nil && info?.lemma != currentSurface
        lemmaLabel.attributedText = show ? info.map { NSAttributedString(string: $0.lemma) } : nil
        lemmaLabel.isHidden = !show
        syncFuriganaToCurrentIndex()
    }

    // Presents the custom reading prompt for the header row tap gesture. Uses
    // JapaneseReadingPromptController (not UIAlertController) so the field is a JapaneseTextField
    // and the Japanese keyboard opens by default for kana entry.
    func presentCustomReadingAlert() {
        guard allowsCustomReading else { return }
        let prompt = JapaneseReadingPromptController(
            title: "Custom Reading",
            initialText: displayedReading() ?? "",
            placeholder: "e.g. よむ",
            showsReset: sheet?.activeReadingOverrideProvider?() != nil,
            onSet: { [weak self] entered in
                self?.customReading = entered
                self?.syncFuriganaToCurrentIndex()
                self?.sheet?.onReadingSelected?(entered)
            },
            onReset: { [weak self] in
                self?.customReading = nil
                self?.currentReadingIndex = 0
                self?.sheet?.onReadingReset?()
                self?.syncFuriganaToCurrentIndex()
                self?.updateMiddleContent()
            })
        present(prompt, animated: true)
    }

    // MARK: - Surface / navigation management

    // Applies a merge or split outcome: updates surface, neighbor labels, and button availability.
    func updateCurrentSurface(_ outcome: (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)) {
        currentSurface = outcome.surface
        currentLeftNeighborSurface = outcome.leftNeighborSurface
        currentRightNeighborSurface = outcome.rightNeighborSurface
        // Clear the header reading until the new segment's providers refresh.
        rebuildHeaderRow(reading: nil)
        splitButton.isEnabled = currentSurface.count > 1 && currentOnSplitApply != nil
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

    // Shows or hides the split editor panel and updates button tint. The sheet has a single
    // content-fitted detent (see contentDetent()), so toggling the panel just re-measures it.
    func setSplitEditorVisible(_ visible: Bool) {
        isSplitEditorVisible = visible
        splitPanelContainer.isHidden = !visible
        splitPanelCollapsedConstraint.isActive = !visible
        // Hide + collapse the definitions while splitting so the taller split panel + header fit
        // without clipping the title.
        middleContentContainer.isHidden = visible
        middleContentCollapsedConstraint.isActive = visible
        splitButton.tintColor = visible ? .label : .secondaryLabel
        invalidateContentDetentIfPresented()
    }

    // A custom detent whose height is the sheet's actual fitted content — header, definitions
    // (or the split editor when it's open) and the action menu — so the sheet never opens with
    // dead space below a short entry, and never clips a long one. Capped at the maximum so a
    // very long cut list (the readout scrolls past its own cap) can't overflow.
    func contentDetent() -> UISheetPresentationController.Detent {
        .custom(identifier: contentDetentIdentifier) { [weak self] context in
            guard let self else { return context.maximumDetentValue }
            // Read-only. viewDidLayoutSubviews owns the measurement: measuring, or resizing
            // anything, from inside a detent resolver re-enters layout. Until the first layout
            // pass has run there is nothing measured, and the sheet opens at a middling height
            // that the pass then corrects.
            guard self.measuredContentHeight > 0 else { return min(340, context.maximumDetentValue) }
            let fitted = self.measuredContentHeight + self.pendingBottomSafeAreaInset()
            return min(max(fitted, 240), context.maximumDetentValue)
        }
    }

    // The home-indicator inset the fitted measurement above is still missing. `systemLayoutSizeFitting`
    // resolves `safeAreaLayoutGuide` constraints against the view's CURRENT insets, which are zero on the
    // very first detent resolution because the sheet's view isn't in a window yet. Sizing the sheet from
    // that measurement leaves it exactly one home-indicator short of its content, and since the action
    // menu is pinned to the safe-area bottom the deficit is taken out of the header — which is what
    // vertically clips the headword. Returning the difference (rather than the raw container inset) keeps
    // later re-measurements, where the view does carry the inset, from counting it twice.
    private func pendingBottomSafeAreaInset() -> CGFloat {
        let containerInset = sheetPresentationController?.containerView?.safeAreaInsets.bottom
            ?? view.window?.safeAreaInsets.bottom
            ?? view.safeAreaInsets.bottom
        return max(0, containerInset - view.safeAreaInsets.bottom)
    }

    // Re-measures the content-fitted detent so the sheet grows or shrinks to match whatever just
    // changed (a different word's sense count, a reading swap, the split editor opening). No-op
    // before the sheet is actually on screen — the initial detent resolution at present time
    // already sizes correctly against the content in place at that point.
    func invalidateContentDetentIfPresented() {
        guard isViewLoaded, view.window != nil, let presentation = sheetPresentationController else { return }
        presentation.animateChanges {
            presentation.invalidateDetents()
        }
    }

    // Resets left and right split values to the cut the segmenter prices cheapest, falling back to a
    // midpoint split while no costs are available.
    func resetSplitInputs(using outcomeSurface: String) {
        rebuildSplitCandidates(for: outcomeSurface)

        let cheapest = splitCandidates
            .compactMap { candidate in candidate.cost.map { (path: candidate.path, cost: $0) } }
            .min { $0.cost < $1.cost }
        if let cheapest {
            leftSplitValue = cheapest.path[0]
            rightSplitValue = cheapest.path[1]
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

        // The readout's row count (and thus the fitted content height) just changed for this segment;
        // recompute the custom detent so the sheet resizes to match instead of keeping the prior word's height.
        if isSplitEditorVisible {
            invalidateContentDetentIfPresented()
        }
    }

    // Recomputes splitCandidates for `surface` — every cut, left to right, costed once by the
    // segmenter through the sheet's splitCostsProvider — and rebuilds the chips and readout from it.
    // Called when the segment changes and again when the segmenter becomes ready.
    func rebuildSplitCandidates(for surface: String) {
        let characters = Array(surface)
        let paths = characters.count >= 2
            ? (1..<characters.count).map { [String(characters[..<$0]), String(characters[$0...])] }
            : []
        let costs = sheet?.splitCostsReady == true ? sheet?.splitCostsProvider?(paths) ?? [] : []
        splitCandidates = paths.enumerated().map { index, path in
            (path: path, cost: costs.indices.contains(index) ? costs[index] : nil)
        }

        guard let row = splitCandidatesRow else { return }
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        splitCandidatesScroll?.isHidden = splitCandidates.count < 2
        updateSplitCostLabel()
        guard splitCandidates.count >= 2 else { return }

        for (index, candidate) in splitCandidates.enumerated() {
            let path = candidate.path
            let chip = UIButton(type: .system)
            var config = UIButton.Configuration.gray()
            config.title = path.joined(separator: "・")
            config.cornerStyle = .capsule
            config.buttonSize = .small
            chip.configuration = config
            chip.tag = index
            chip.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.leftSplitValue = path[0]
                self.rightSplitValue = path[1]
                self.leftInput.text = path[0]
                self.rightInput.text = path[1]
                self.applySplitButton.isEnabled = true
                self.applySplitButton.alpha = 1
                self.leftInputTapButton.isEnabled = true
                self.leftInputTapButton.alpha = 1
                self.rightInputTapButton.isEnabled = true
                self.rightInputTapButton.alpha = 1
            }, for: .touchUpInside)
            row.addArrangedSubview(chip)
        }
        refreshSplitCandidateSelection()
    }

    // Highlights whichever candidate chip matches the current left/right split values so chip taps
    // and manual boundary nudges (the ↔ controls) stay visually in sync. No-op before the chip row
    // is built or when the active split isn't one of the enumerated candidates.
    func refreshSplitCandidateSelection() {
        guard let row = splitCandidatesRow else { return }
        for case let chip as UIButton in row.arrangedSubviews {
            let path = splitCandidates.indices.contains(chip.tag) ? splitCandidates[chip.tag].path : []
            let isActive = path == [leftSplitValue, rightSplitValue]
            chip.configuration?.baseBackgroundColor = isActive ? UIColor.systemBlue.withAlphaComponent(0.25) : nil
            chip.configuration?.baseForegroundColor = isActive ? .systemBlue : .label
        }
    }

    // Lists every cut of the segment, left to right, each with what the segmenter charges for the
    // line cut that way (in nats; lower is what segmentation would pick). The numbers come from
    // splitCandidates — the segmenter's own path costs — so the readout cannot disagree with the
    // segmentation. The current split is bolded and marked with ▸ so the readout stays tied to the
    // chips / [] ↔ [] inputs. Driven by the leftSplitValue/rightSplitValue didSet observers and
    // re-invoked by rebuildSplitCandidates whenever the segment or the segmenter changes.
    func updateSplitCostLabel() {
        guard let label = splitCostLabel else { return }
        guard let sheet, splitCandidates.isEmpty == false else {
            label.attributedText = nil
            label.isHidden = true
            return
        }

        // The segmenter loads a few seconds after launch; a split editor opened before then has no
        // costs. Show a loading state — the readout refreshes itself once it lands (see
        // refreshOpenSheetSplitCostsProvider).
        guard sheet.splitCostsReady else {
            label.isHidden = false
            label.attributedText = NSAttributedString(string: "Loading…", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.tertiaryLabel,
            ])
            return
        }

        // marker \t left・right \t cost — the cost column is placed past the widest cut.
        let activeSplit = [leftSplitValue, rightSplitValue]
        // Rendered width of a string in the readout font, used to position the cost tab stop.
        // Measured at the bold weight (the widest any row renders) so plain rows never overrun it.
        func glyphWidth(_ string: String) -> CGFloat {
            let font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            return ceil((string as NSString).size(withAttributes: [.font: font]).width)
        }
        let cutColumn: CGFloat = 14                                    // after the ▸ marker
        let maxCut = splitCandidates.map { glyphWidth($0.path.joined(separator: "・")) }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: cutColumn, options: [:]),
            NSTextTab(textAlignment: .left, location: cutColumn + maxCut + 12, options: [:]),
        ]
        paragraph.lineBreakMode = .byClipping

        let body = NSMutableAttributedString()
        for (index, candidate) in splitCandidates.enumerated() {
            let isActive = candidate.path == activeSplit
            let cost = candidate.cost.map { String(format: "%.1f", Double($0) / 100) } ?? "–"
            let line = "\(isActive ? "▸" : "")\t\(candidate.path.joined(separator: "・"))\t\(cost)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? UIColor.label : UIColor.secondaryLabel,
                .paragraphStyle: paragraph,
            ]
            body.append(NSAttributedString(string: line, attributes: attributes))
            if index < splitCandidates.count - 1 { body.append(NSAttributedString(string: "\n")) }
        }
        label.isHidden = false
        label.attributedText = body
    }

    // MARK: - Content and height

    // Delegates middle content rebuild to the sheet coordinator which holds shared data.
    // Passes self so compound-component chips can present nested lookup sheets, and the currently
    // displayed reading so the gloss can match it (e.g. 様/よう → "appearance" not "Mr/Mrs/...").
    func updateMiddleContent() {
        sheet?.updateMiddleContent(
            in: middleContentStack,
            parent: self,
            selectedReading: displayedReading(),
            selectedKanji: currentSurface
        )
        invalidateContentDetentIfPresented()
    }

    // Refreshes the save button icon and tint to reflect the current saved state, the same
    // encoding as the extract-words list stars: filled yellow = saved, hollow gray = not saved.
    func updateSaveButtonAppearance() {
        let isSaved = sheet?.sheetIsSavedProvider?() ?? false
        let learnedState = sheet?.sheetLearnedStateProvider?() ?? .unmarked
        let icon: String
        switch learnedState {
        case .learned:    icon = "checkmark"
        case .notLearned: icon = "questionmark"
        case .unmarked:   icon = isSaved ? "star.fill" : "star"
        }
        saveButton.setImage(UIImage(systemName: icon), for: .normal)
        saveButton.tintColor = (learnedState != .unmarked || isSaved) ? .systemYellow : .secondaryLabel
        saveButton.accessibilityLabel = isSaved ? "Unsave" : "Save"
        // Rebuilt on every refresh so the menu's setState closure always targets the currently
        // shown word, mirroring SegmentLookupSheet's popover star (see its refresh comment).
        if let setLearnedState = sheet?.sheetSetLearnedState {
            // Deferred write + self-refresh for the same reason as the popover star: applying the
            // mark inline collides with the menu's teardown and the icon flips a beat late.
            saveButton.menu = learnedStateUIMenu(currentState: learnedState) { [weak self] state in
                DispatchQueue.main.async {
                    setLearnedState(state)
                    self?.updateSaveButtonAppearance()
                }
            }
            saveButton.showsMenuAsPrimaryAction = false
        } else {
            saveButton.menu = nil
        }
    }

    // Reflects whether the current surface resolved to a dictionary entry that can be opened.
    func updateOpenDetailButtonAppearance() {
        let hasDictionaryEntry = sheet?.currentSheetDictionaryEntry != nil
        openDetailButton.isEnabled = hasDictionaryEntry
        openDetailButton.alpha = hasDictionaryEntry ? 1 : 0.45
    }

}
