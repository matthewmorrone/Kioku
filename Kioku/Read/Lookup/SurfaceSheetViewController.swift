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

    var leftSplitValue = "" { didSet { updateSplitFrequencyLabel(); refreshSplitCandidateSelection() } }
    var rightSplitValue = "" { didSet { updateSplitFrequencyLabel(); refreshSplitCandidateSelection() } }
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
    // room the taller split panel needs so the fixed `.medium` detent doesn't clip the header title.
    var middleContentCollapsedConstraint: NSLayoutConstraint!
    // Identifier for the content-fitted detent used while the split editor is open (see splitContentDetent()).
    let splitContentDetentIdentifier = UISheetPresentationController.Detent.Identifier("kioku.splitContent")
    var leftInput: UITextField!
    var rightInput: UITextField!
    var leftInputTapButton: UIButton!
    var rightInputTapButton: UIButton!
    var splitButton: UIButton!
    var cancelSplitButton: UIButton!
    var applySplitButton: UIButton!
    // Shows the per-piece frequency scores behind the current split (below the [] ↔ [] inputs).
    var splitFrequencyLabel: UILabel?
    // Scroll container for the split readout; lets it scroll instead of clipping when there are more
    // cut rows than the fixed medium detent can show.
    var splitFrequencyScroll: UIScrollView?
    // Horizontally-scrolling row of selectable two-way split candidates (one chip per valid
    // sublattice split). Surfaces the full set — e.g. both どこ・かに and どこか・に — instead of
    // only the single auto-proposed best split. Hidden when there are fewer than two candidates.
    var splitCandidatesScroll: UIScrollView?
    var splitCandidatesRow: UIStackView?
    // Backing data for the candidate chips: each entry is a [left, right] two-segment path. Chip
    // tag is its index here, so taps and the active-selection highlight can resolve back to a path.
    var splitCandidatePaths: [[String]] = []
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
        splitButton.isEnabled = currentSurface.count > 1 && currentOnSplitApply != nil
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
        alert.addAction(UIAlertAction(title: "Set", style: .default) { [weak self] _ in
            let entered = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard entered.isEmpty == false else { return }
            self?.customReading = entered
            self?.syncFuriganaToCurrentIndex()
            self?.sheet?.onReadingSelected?(entered)
        })
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

    // Shows or hides the split editor panel and updates button tint. Sheet height stays
    // fixed at `.medium()` — the split editor expands inside the existing sheet bounds.
    func setSplitEditorVisible(_ visible: Bool) {
        isSplitEditorVisible = visible
        splitPanelContainer.isHidden = !visible
        splitPanelCollapsedConstraint.isActive = !visible
        // Hide + collapse the definitions while splitting so the taller split panel + header fit
        // without clipping the title.
        middleContentContainer.isHidden = visible
        middleContentCollapsedConstraint.isActive = visible
        splitButton.tintColor = visible ? .label : .secondaryLabel

        // Built-in detents are coarse (.medium ≈ half, .large ≈ full), so opening the split editor
        // used to snap the sheet to full height. Instead use a custom detent sized to the split UI's
        // actual content height — the sheet grows by exactly what the cut list needs, no big jump.
        if let presentation = sheetPresentationController {
            presentation.animateChanges {
                presentation.detents = visible ? [.medium(), splitContentDetent()] : [.medium()]
                presentation.largestUndimmedDetentIdentifier = visible ? splitContentDetentIdentifier : .medium
                presentation.selectedDetentIdentifier = visible ? splitContentDetentIdentifier : .medium
            }
        }
    }

    // A custom detent whose height is the split UI's fitted content height, so the sheet sits exactly
    // as tall as header + split panel + toolbar require instead of snapping to .medium/.large. Capped
    // at the maximum so a very long cut list (the readout scrolls past its own cap) can't overflow.
    func splitContentDetent() -> UISheetPresentationController.Detent {
        .custom(identifier: splitContentDetentIdentifier) { [weak self] context in
            guard let self else { return context.maximumDetentValue }
            self.view.layoutIfNeeded()
            let fitted = self.view.systemLayoutSizeFitting(
                CGSize(width: self.view.bounds.width, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height + self.view.safeAreaInsets.bottom
            return min(max(fitted, 240), context.maximumDetentValue)
        }
    }

    // Resets left and right split values to the highest-scoring two-segment sublattice path,
    // falling back to a midpoint split when no two-segment path exists.
    func resetSplitInputs(using outcomeSurface: String) {
        guard let sheet else { return }

        // Looks up the frequency-based score for a single segment candidate.
        func segmentScore(_ segment: String) -> Double {
            sheet.pathSegmentFrequencyProvider?(segment).flatMap { sheet.normalizedSheetFrequencyScore($0) } ?? 0
        }

        // Averages segment scores across a full path to find the highest-quality two-segment split.
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

        rebuildSplitCandidates()

        // The readout's row count (and thus the fitted content height) just changed for this segment;
        // recompute the custom detent so the sheet resizes to match instead of keeping the prior word's height.
        if isSplitEditorVisible {
            sheetPresentationController?.invalidateDetents()
        }
    }

    // Rebuilds the chip row from every distinct two-segment sublattice split, highest average
    // frequency first (the same signal resetSplitInputs averages to pick its default). Surfaces
    // the full set — どこかに yields both どこ・かに and どこか・に — so a non-default split is one tap
    // away instead of requiring the user to nudge the boundary character-by-character. Hidden when
    // there are fewer than two candidates (nothing to choose between).
    func rebuildSplitCandidates() {
        guard let row = splitCandidatesRow, let sheet else { return }
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // Looks up the frequency-based score for a single segment candidate.
        func segmentScore(_ segment: String) -> Double {
            sheet.pathSegmentFrequencyProvider?(segment).flatMap { sheet.normalizedSheetFrequencyScore($0) } ?? 0
        }
        // Averages segment scores across a full path to rank candidate splits.
        func pathScore(_ path: [String]) -> Double {
            path.map(segmentScore).reduce(0, +) / max(1, Double(path.count))
        }

        var seen: Set<String> = []
        let twoPaths = sheet.sublatticeValidPaths(from: sheet.currentSheetSublatticeEdges)
            .filter { $0.count == 2 }
            .filter { seen.insert($0.joined(separator: "·")).inserted }
            .sorted { pathScore($0) > pathScore($1) }
        splitCandidatePaths = twoPaths

        splitCandidatesScroll?.isHidden = twoPaths.count < 2
        // Re-evaluate the frequency readout's gate now that splitCandidatePaths reflects THIS segment
        // (its didSet-driven update ran earlier against the previous segment's count).
        updateSplitFrequencyLabel()
        guard twoPaths.count >= 2 else { return }

        for (index, path) in twoPaths.enumerated() {
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
            let path = splitCandidatePaths.indices.contains(chip.tag) ? splitCandidatePaths[chip.tag] : []
            let isActive = path == [leftSplitValue, rightSplitValue]
            chip.configuration?.baseBackgroundColor = isActive ? UIColor.systemBlue.withAlphaComponent(0.25) : nil
            chip.configuration?.baseForegroundColor = isActive ? .systemBlue : .label
        }
    }

    // Lists EVERY available way to cut the segment currently being split (all sublattice paths, not
    // just two-piece cuts), each shown with its full score calculation: every segment's frequency
    // score and their sum. This is the exact signal that ranks the candidates, laid bare so the user
    // can see *why* one split outscores another rather than trusting an opaque number. The currently
    // selected split is bolded and marked with ▸ so this transparency view stays tied to the chips /
    // [] ↔ [] inputs. Driven by the leftSplitValue/rightSplitValue didSet observers and re-invoked by
    // rebuildSplitCandidates whenever the sublattice changes.
    func updateSplitFrequencyLabel() {
        guard let label = splitFrequencyLabel else { return }
        guard let sheet else {
            label.attributedText = nil
            label.isHidden = true
            return
        }

        // The frequency maps build a few seconds after launch; a split editor opened before they're
        // ready would score every piece 0. Show a loading state instead of misleading zeros — the
        // readout refreshes itself once resources land (see refreshOpenSheetFrequencyProvider).
        guard sheet.frequencyResourcesReady else {
            label.isHidden = false
            label.attributedText = NSAttributedString(string: "Loading frequencies…", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.tertiaryLabel,
            ])
            return
        }

        // Frequency score for a single segment surface (0 when it has no frequency data).
        func segmentScore(_ surface: String) -> Double {
            sheet.pathSegmentFrequencyProvider?(surface).flatMap { sheet.normalizedSheetFrequencyScore($0) } ?? 0
        }

        // One row per possibility the menu can actually produce: a single left/right cut at EVERY
        // character boundary of the segment (どこかに → ど・こかに, どこ・かに, どこか・に), not just the
        // dictionary-valid sublattice paths — those dropped legitimate cuts like ど・こかに. Each piece
        // is scored independently (0 when it isn't a known word). Rows stay in left-to-right cut order
        // (cut after char 1, then 2, …) so the list reads in the same direction as the text.
        let characters = Array(currentSurface)
        let scored = characters.count >= 2
            ? (1..<characters.count).map { cut -> (path: [String], scores: [Double], sum: Double) in
                let left = String(characters[0..<cut])
                let right = String(characters[cut...])
                let scores = [segmentScore(left), segmentScore(right)]
                return ([left, right], scores, scores.reduce(0, +))
            }
            : []

        guard scored.isEmpty == false else {
            label.attributedText = nil
            label.isHidden = true
            return
        }

        // Every row is exactly two pieces (seg1 score1 + seg2 score2 = total), so the SCORES can be
        // aligned into columns even though the Japanese segment text is variable width. Tab stops are
        // placed by measuring the widest seg1/seg2 in this set:
        //   ▸ どこか 3.0 + に  4.3 = 7.3
        //     どこ   3.1 + かに 2.8 = 5.9
        // Marker, seg1-start, score1, and score2 each get a tab stop; "+ ", " = " and the total ride
        // inline (score cells are fixed-width monospaced digits, so the total stays put after them).
        let activeSplit = [leftSplitValue, rightSplitValue]
        // Rendered width of a string in the readout font, used to position the score tab stops.
        // Measured at the bold weight (the widest any row renders) so plain rows never overrun a stop.
        func glyphWidth(_ string: String) -> CGFloat {
            let font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            return ceil((string as NSString).size(withAttributes: [.font: font]).width)
        }
        let gap: CGFloat = 8
        let seg1Column: CGFloat = 14                                   // after the ▸ marker
        let maxSeg1 = scored.map { glyphWidth($0.path[0]) }.max() ?? 0
        let score1Column = seg1Column + maxSeg1 + gap
        let interWidth = glyphWidth("0.0 + ")                          // score1 + " + " (fixed width)
        let maxSeg2 = scored.map { glyphWidth($0.path[1]) }.max() ?? 0
        let score2Column = score1Column + interWidth + maxSeg2 + gap

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: seg1Column, options: [:]),
            NSTextTab(textAlignment: .left, location: score1Column, options: [:]),
            NSTextTab(textAlignment: .left, location: score2Column, options: [:]),
        ]
        paragraph.lineBreakMode = .byClipping

        let body = NSMutableAttributedString()
        for (index, entry) in scored.enumerated() {
            let isActive = entry.path == activeSplit
            let score1 = String(format: "%.1f", entry.scores[0])
            let score2 = String(format: "%.1f", entry.scores[1])
            let total = String(format: "%.1f", entry.sum)
            // marker \t seg1 \t score1 + seg2 \t score2 = total
            let line = "\(isActive ? "▸" : "")\t\(entry.path[0])\t\(score1) + \(entry.path[1])\t\(score2) = \(total)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: isActive ? .semibold : .regular),
                .foregroundColor: isActive ? UIColor.label : UIColor.secondaryLabel,
                .paragraphStyle: paragraph,
            ]
            body.append(NSAttributedString(string: line, attributes: attributes))
            if index < scored.count - 1 { body.append(NSAttributedString(string: "\n")) }
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
        openDetailButton.isEnabled = hasDictionaryEntry
        openDetailButton.alpha = hasDictionaryEntry ? 1 : 0.45
    }

}
