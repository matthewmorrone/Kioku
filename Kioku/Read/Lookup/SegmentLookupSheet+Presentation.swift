import UIKit
import SwiftUI
import AVFoundation

extension SegmentLookupSheet {
    // Presents a bottom sheet that starts at a fitted small detent and can expand to medium.
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
        // Capture callbacks before dismissPopover, since dismissSheet clears them.
        let capturedOnReadingSelected = self.onReadingSelected
        let capturedPathSegmentFrequencyProvider = self.pathSegmentFrequencyProvider
        let capturedSheetLemmaInfoProvider = self.sheetLemmaInfoProvider
        let capturedSheetWordDisplayDataProvider = self.sheetWordDisplayDataProvider
        let capturedSheetIsSavedProvider = self.sheetIsSavedProvider
        let capturedSheetSaveToggle = self.sheetSaveToggle
        let capturedSheetWordComponentsProvider = self.sheetWordComponentsProvider
        let capturedActiveReadingOverrideProvider = self.activeReadingOverrideProvider
        let capturedOnReadingReset = self.onReadingReset
        dismissPopover(notifyDismissal: false) { [weak self] in
            guard let self, let presenter = self.topPresentingController() else {
                return
            }

            self.onDismiss = onDismiss
            self.onReadingSelected = capturedOnReadingSelected
            self.onReadingReset = capturedOnReadingReset
            self.pathSegmentFrequencyProvider = capturedPathSegmentFrequencyProvider
            self.sheetLemmaInfoProvider = capturedSheetLemmaInfoProvider
            self.sheetWordDisplayDataProvider = capturedSheetWordDisplayDataProvider
            self.sheetIsSavedProvider = capturedSheetIsSavedProvider
            self.sheetSaveToggle = capturedSheetSaveToggle
            self.sheetWordComponentsProvider = capturedSheetWordComponentsProvider
            self.activeReadingOverrideProvider = capturedActiveReadingOverrideProvider
            self.onSheetSelectPrevious = nil
            self.onSheetSelectNext = nil
            self.sheetReadingsProvider = sheetReadingsProvider
            self.sheetSublatticeProvider = sheetSublatticeProvider
            self.segmentRangeProvider = segmentRangeProvider
            self.sheetLexiconDebugProvider = sheetLexiconDebugProvider
            self.sheetFrequencyProvider = sheetFrequencyProvider
            self.refreshSheetSupplementalData()

            var currentSurface = surface

            let sheetController = UIViewController()
            sheetController.view.backgroundColor = .systemBackground
            // Keeps content clear of the grabber area so the title is never clipped.
            sheetController.additionalSafeAreaInsets.top = 20

            // SwiftUI header — mirrors WordDetailView header exactly.
            let headerReading: String? = self.currentSheetUniqueReadings.first
            let headerLemma: String? = self.currentSheetLemmaInfo.map { $0.lemma }
            let headerView = SegmentLookupSheetHeader(surface: surface, reading: headerReading, lemma: headerLemma)
            let headerHost = UIHostingController(rootView: headerView)
            // sizingOptions must be set before the view is added to a parent so Auto Layout
            // uses SwiftUI's ideal size — needed since FuriganaView computes height via CoreText.
            if #available(iOS 16.0, *) {
                headerHost.sizingOptions = .intrinsicContentSize
            }
            headerHost.view.translatesAutoresizingMaskIntoConstraints = false
            headerHost.view.backgroundColor = .clear

            // Header with per-kanji-run furigana centered above each headword.
            let headwordFont = UIFont.systemFont(ofSize: 34, weight: .bold)
            let rubyFont = UIFont.systemFont(ofSize: 17)

            // Builds the header as a horizontal stack of columns. Kanji runs get a small
            // reading label centered above; kana runs sit at the baseline with an empty
            // spacer above so all columns share the same top-to-baseline geometry.
            func buildHeaderSubviews(surface: String, reading: String) -> [UIView] {
                let chars = Array(surface)
                let runs = FuriganaAttributedString.kanjiRuns(in: surface)
                let readings = FuriganaAttributedString.projectRunReadings(surface: surface, reading: reading, runs: runs)

                // Segments: alternating kana and kanji chunks with their per-run readings.
                struct Segment {
                    let text: String
                    let ruby: String? // nil for kana-only segments
                }

                var segments: [Segment] = []
                var cursor = 0
                for (i, run) in runs.enumerated() {
                    // Kana before this kanji run.
                    if cursor < run.start {
                        segments.append(Segment(text: String(chars[cursor..<run.start]), ruby: nil))
                    }
                    let kanjiText = String(chars[run.start..<run.end])
                    let ruby = readings.flatMap { $0.indices.contains(i) ? $0[i] : nil }
                    segments.append(Segment(text: kanjiText, ruby: (ruby != nil && ruby != kanjiText) ? ruby : nil))
                    cursor = run.end
                }
                // Trailing kana after last kanji run.
                if cursor < chars.count {
                    segments.append(Segment(text: String(chars[cursor...]), ruby: nil))
                }

                // No kanji runs at all — single plain label.
                if segments.isEmpty {
                    let label = UILabel()
                    label.font = headwordFont
                    label.text = surface
                    label.textAlignment = .center
                    return [label]
                }

                return segments.map { segment in
                    let headwordLabel = UILabel()
                    headwordLabel.font = headwordFont
                    headwordLabel.text = segment.text
                    headwordLabel.textAlignment = .center

                    let rubyLabel = UILabel()
                    rubyLabel.font = rubyFont
                    rubyLabel.textColor = .secondaryLabel
                    rubyLabel.textAlignment = .center
                    rubyLabel.text = segment.ruby
                    // Invisible spacer when no ruby — preserves vertical alignment across columns.
                    rubyLabel.alpha = segment.ruby != nil ? 1 : 0

                    let column = UIStackView(arrangedSubviews: [rubyLabel, headwordLabel])
                    column.axis = .vertical
                    column.alignment = .center
                    column.spacing = 2
                    return column
                }
            }

            let initialReading = self.currentSheetUniqueReadings.first ?? ""
            let headerRow = UIStackView(arrangedSubviews: buildHeaderSubviews(surface: surface, reading: initialReading))
            headerRow.axis = .horizontal
            headerRow.alignment = .bottom
            headerRow.spacing = 0

            // Wrapper centers the row horizontally within the sheet.
            let headerStack = UIStackView(arrangedSubviews: [headerRow])
            headerStack.translatesAutoresizingMaskIntoConstraints = false
            headerStack.axis = .vertical
            headerStack.alignment = .center

            let prevReadingButton = UIButton(type: .system)
            prevReadingButton.translatesAutoresizingMaskIntoConstraints = false
            prevReadingButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            prevReadingButton.tintColor = .tertiaryLabel

            let nextReadingButton = UIButton(type: .system)
            nextReadingButton.translatesAutoresizingMaskIntoConstraints = false
            nextReadingButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
            nextReadingButton.tintColor = .tertiaryLabel

            // Arrows are laid out independently so their centerY can be pinned to the headword text row,
            // which sits below the furigana inset — stack alignment can't express this offset cleanly.
            let furiganaInset: CGFloat = UIFont.systemFont(ofSize: 34 * 0.5).lineHeight + CGFloat(TypographySettings.defaultFuriganaGap)

            var currentReadingIndex = 0
            var currentReadings: [String] = self.currentSheetUniqueReadings
            var customReading: String? = nil
            // Custom slot and navigation arrows are only relevant for kanji-bearing segments.
            var showCustomSlot = ScriptClassifier.containsKanji(surface)

            // True when the current index points to the custom-entry slot (always the last slot).
            func isOnCustomSlot() -> Bool {
                showCustomSlot && currentReadingIndex == currentReadings.count
            }

            // Total navigable slots: dictionary readings plus the custom slot when applicable.
            func totalSlots() -> Int {
                showCustomSlot ? currentReadings.count + 1 : currentReadings.count
            }

            // Updates the SwiftUI header to reflect the reading at the current index.
            // When on the empty custom slot, shows "..." as a tap affordance.
            func syncFuriganaToCurrentIndex() {
                let reading: String?
                if isOnCustomSlot() {
                    reading = customReading ?? "..."
                } else if currentReadings.indices.contains(currentReadingIndex) {
                    reading = currentReadings[currentReadingIndex]
                } else {
                    reading = nil
                }
                let lemma = self.currentSheetLemmaInfo.map { $0.lemma }
                headerHost.rootView = SegmentLookupSheetHeader(surface: currentSurface, reading: reading, lemma: lemma)
            }

            // Refreshes header for the current segment surface.
            // Initializes the selected index from any persisted override so the UI reflects prior choices.
            func updateReadingFurigana() {
                currentReadings = self.currentSheetUniqueReadings
                showCustomSlot = ScriptClassifier.containsKanji(currentSurface)

                let activeOverride = self.activeReadingOverrideProvider?()
                if let override = activeOverride, let idx = currentReadings.firstIndex(of: override) {
                    currentReadingIndex = idx
                    customReading = nil
                } else if showCustomSlot, let override = activeOverride, currentReadings.contains(override) == false {
                    currentReadingIndex = currentReadings.count // custom slot
                    customReading = override
                } else {
                    currentReadingIndex = 0
                    customReading = nil
                }
                // Clamp index in case segment changed and custom slot is no longer available.
                if currentReadingIndex >= totalSlots() {
                    currentReadingIndex = 0
                    customReading = nil
                }

                // print("[SegmentLookupSheet] updateReadingFurigana: surface=\(currentSurface) readings=\(currentReadings) index=\(currentReadingIndex)")

                syncFuriganaToCurrentIndex()
                // Show arrows for any kanji segment — custom reading entry is always available.
                prevReadingButton.isHidden = !showCustomSlot
                nextReadingButton.isHidden = !showCustomSlot
            }

            // Updates the lemma in the header.
            func updateLemmaChain() {
                syncFuriganaToCurrentIndex()
            }

            let splitPanelContainer = UIStackView()
            splitPanelContainer.translatesAutoresizingMaskIntoConstraints = false
            splitPanelContainer.axis = .vertical
            splitPanelContainer.spacing = 14
            splitPanelContainer.isHidden = true
            // isHidden doesn't collapse Auto Layout frames — explicit zero height prevents the
            // hidden split panel from pushing content out of the sheet's visible bounds.
            let splitPanelCollapsedConstraint = splitPanelContainer.heightAnchor.constraint(equalToConstant: 0)
            splitPanelCollapsedConstraint.isActive = true

            let splitInputsRow = UIStackView()
            splitInputsRow.axis = .horizontal
            splitInputsRow.spacing = 12
            splitInputsRow.alignment = .center
            splitInputsRow.distribution = .fill

            let leftInput = UITextField()
            leftInput.translatesAutoresizingMaskIntoConstraints = false
            leftInput.borderStyle = .roundedRect
            leftInput.font = .systemFont(ofSize: 22, weight: .medium)
            leftInput.textColor = .label
            leftInput.placeholder = "Left"
            leftInput.isUserInteractionEnabled = false
            leftInput.textAlignment = .right

            let rightInput = UITextField()
            rightInput.translatesAutoresizingMaskIntoConstraints = false
            rightInput.borderStyle = .roundedRect
            rightInput.font = .systemFont(ofSize: 22, weight: .medium)
            rightInput.textColor = .label
            rightInput.placeholder = "Right"
            rightInput.isUserInteractionEnabled = false
            rightInput.textAlignment = .left

            let leftInputContainer = UIView()
            leftInputContainer.translatesAutoresizingMaskIntoConstraints = false
            let leftInputTapButton = UIButton(type: .custom)
            leftInputTapButton.translatesAutoresizingMaskIntoConstraints = false
            leftInputTapButton.backgroundColor = .clear
            leftInputContainer.addSubview(leftInput)
            leftInputContainer.addSubview(leftInputTapButton)
            NSLayoutConstraint.activate([
                leftInput.topAnchor.constraint(equalTo: leftInputContainer.topAnchor),
                leftInput.leadingAnchor.constraint(equalTo: leftInputContainer.leadingAnchor),
                leftInput.trailingAnchor.constraint(equalTo: leftInputContainer.trailingAnchor),
                leftInput.bottomAnchor.constraint(equalTo: leftInputContainer.bottomAnchor),

                leftInputTapButton.topAnchor.constraint(equalTo: leftInputContainer.topAnchor),
                leftInputTapButton.leadingAnchor.constraint(equalTo: leftInputContainer.leadingAnchor),
                leftInputTapButton.trailingAnchor.constraint(equalTo: leftInputContainer.trailingAnchor),
                leftInputTapButton.bottomAnchor.constraint(equalTo: leftInputContainer.bottomAnchor),
            ])

            let rightInputContainer = UIView()
            rightInputContainer.translatesAutoresizingMaskIntoConstraints = false
            let rightInputTapButton = UIButton(type: .custom)
            rightInputTapButton.translatesAutoresizingMaskIntoConstraints = false
            rightInputTapButton.backgroundColor = .clear
            rightInputContainer.addSubview(rightInput)
            rightInputContainer.addSubview(rightInputTapButton)
            NSLayoutConstraint.activate([
                rightInput.topAnchor.constraint(equalTo: rightInputContainer.topAnchor),
                rightInput.leadingAnchor.constraint(equalTo: rightInputContainer.leadingAnchor),
                rightInput.trailingAnchor.constraint(equalTo: rightInputContainer.trailingAnchor),
                rightInput.bottomAnchor.constraint(equalTo: rightInputContainer.bottomAnchor),

                rightInputTapButton.topAnchor.constraint(equalTo: rightInputContainer.topAnchor),
                rightInputTapButton.leadingAnchor.constraint(equalTo: rightInputContainer.leadingAnchor),
                rightInputTapButton.trailingAnchor.constraint(equalTo: rightInputContainer.trailingAnchor),
                rightInputTapButton.bottomAnchor.constraint(equalTo: rightInputContainer.bottomAnchor),
            ])

            let splitMoveControls = UIStackView()
            splitMoveControls.axis = .vertical
            splitMoveControls.spacing = 8
            splitMoveControls.alignment = .center
            splitMoveControls.distribution = .fillEqually

            let moveLeftIcon = UIImageView(image: UIImage(systemName: "arrow.left"))
            moveLeftIcon.translatesAutoresizingMaskIntoConstraints = false
            moveLeftIcon.tintColor = .secondaryLabel

            let moveRightIcon = UIImageView(image: UIImage(systemName: "arrow.right"))
            moveRightIcon.translatesAutoresizingMaskIntoConstraints = false
            moveRightIcon.tintColor = .secondaryLabel

            splitMoveControls.addArrangedSubview(moveLeftIcon)
            splitMoveControls.addArrangedSubview(moveRightIcon)

            let splitActionsRow = UIStackView()
            splitActionsRow.axis = .horizontal
            splitActionsRow.spacing = 12
            splitActionsRow.alignment = .fill
            splitActionsRow.distribution = .fillEqually

            let cancelSplitButton = UIButton(type: .system)
            cancelSplitButton.translatesAutoresizingMaskIntoConstraints = false
            cancelSplitButton.setTitle("Cancel", for: .normal)
            cancelSplitButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            cancelSplitButton.tintColor = .systemBlue
            cancelSplitButton.backgroundColor = .tertiarySystemFill
            cancelSplitButton.layer.cornerRadius = 22

            let applySplitButton = UIButton(type: .system)
            applySplitButton.translatesAutoresizingMaskIntoConstraints = false
            applySplitButton.setTitle("Apply", for: .normal)
            applySplitButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            applySplitButton.tintColor = .systemBlue
            applySplitButton.backgroundColor = .tertiarySystemFill
            applySplitButton.layer.cornerRadius = 22

            splitActionsRow.addArrangedSubview(cancelSplitButton)
            splitActionsRow.addArrangedSubview(applySplitButton)

            splitInputsRow.addArrangedSubview(leftInputContainer)
            splitInputsRow.addArrangedSubview(splitMoveControls)
            splitInputsRow.addArrangedSubview(rightInputContainer)

            NSLayoutConstraint.activate([
                leftInputContainer.heightAnchor.constraint(equalToConstant: 58),
                rightInputContainer.heightAnchor.constraint(equalToConstant: 58),
                moveLeftIcon.widthAnchor.constraint(equalToConstant: 28),
                moveLeftIcon.heightAnchor.constraint(equalToConstant: 22),
                moveRightIcon.widthAnchor.constraint(equalToConstant: 28),
                moveRightIcon.heightAnchor.constraint(equalToConstant: 22),
                cancelSplitButton.heightAnchor.constraint(equalToConstant: 44),
                applySplitButton.heightAnchor.constraint(equalToConstant: 44),
            ])

            splitPanelContainer.addArrangedSubview(splitInputsRow)
            splitPanelContainer.addArrangedSubview(splitActionsRow)

            let actionMenuContainer = UIView()
            actionMenuContainer.translatesAutoresizingMaskIntoConstraints = false
            actionMenuContainer.backgroundColor = .secondarySystemBackground
            actionMenuContainer.layer.cornerRadius = 10

            // Top row: word actions (speak, save, open in word detail).
            let wordActionsStack = UIStackView()
            wordActionsStack.translatesAutoresizingMaskIntoConstraints = false
            wordActionsStack.axis = .horizontal
            wordActionsStack.spacing = 8
            wordActionsStack.alignment = .fill
            wordActionsStack.distribution = .fillEqually

            let speakButton = UIButton(type: .system)
            speakButton.translatesAutoresizingMaskIntoConstraints = false
            speakButton.setImage(UIImage(systemName: "speaker.wave.2"), for: .normal)
            speakButton.tintColor = .secondaryLabel
            speakButton.backgroundColor = .tertiarySystemFill
            speakButton.layer.cornerRadius = 8
            speakButton.accessibilityLabel = "Speak"

            let saveButton = UIButton(type: .system)
            saveButton.translatesAutoresizingMaskIntoConstraints = false
            let isSavedInitially = self.sheetIsSavedProvider?() ?? false
            saveButton.setImage(UIImage(systemName: isSavedInitially ? "star.fill" : "star"), for: .normal)
            saveButton.tintColor = isSavedInitially ? .systemYellow : .secondaryLabel
            saveButton.backgroundColor = .tertiarySystemFill
            saveButton.layer.cornerRadius = 8
            saveButton.accessibilityLabel = isSavedInitially ? "Unsave" : "Save"

            let openDetailButton = UIButton(type: .system)
            openDetailButton.translatesAutoresizingMaskIntoConstraints = false
            openDetailButton.setImage(UIImage(systemName: "text.magnifyingglass"), for: .normal)
            openDetailButton.tintColor = .secondaryLabel
            openDetailButton.backgroundColor = .tertiarySystemFill
            openDetailButton.layer.cornerRadius = 8
            openDetailButton.accessibilityLabel = "Open Word Detail"

            // Refreshes the save button icon and tint to reflect the current saved state.
            func updateSaveButtonAppearance() {
                let isSaved = self.sheetIsSavedProvider?() ?? false
                let imageName = isSaved ? "star.fill" : "star"
                saveButton.setImage(UIImage(systemName: imageName), for: .normal)
                saveButton.tintColor = isSaved ? .systemYellow : .secondaryLabel
                saveButton.accessibilityLabel = isSaved ? "Unsave" : "Save"
            }

            wordActionsStack.addArrangedSubview(speakButton)
            wordActionsStack.addArrangedSubview(saveButton)
            wordActionsStack.addArrangedSubview(openDetailButton)

            // Bottom row: segmentation actions (merge-left, split, merge-right).
            let actionMenuStack = UIStackView()
            actionMenuStack.translatesAutoresizingMaskIntoConstraints = false
            actionMenuStack.axis = .horizontal
            actionMenuStack.spacing = 8
            actionMenuStack.alignment = .fill
            actionMenuStack.distribution = .fillEqually

            let mergeLeftButton = UIButton(type: .system)
            mergeLeftButton.translatesAutoresizingMaskIntoConstraints = false
            mergeLeftButton.setImage(UIImage(systemName: "arrow.left.to.line.compact"), for: .normal)
            mergeLeftButton.tintColor = .secondaryLabel
            mergeLeftButton.backgroundColor = .tertiarySystemFill
            mergeLeftButton.layer.cornerRadius = 8

            let splitButton = UIButton(type: .system)
            splitButton.translatesAutoresizingMaskIntoConstraints = false
            splitButton.setImage(UIImage(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right"), for: .normal)
            splitButton.tintColor = .secondaryLabel
            splitButton.backgroundColor = .tertiarySystemFill
            splitButton.layer.cornerRadius = 8

            let mergeRightButton = UIButton(type: .system)
            mergeRightButton.translatesAutoresizingMaskIntoConstraints = false
            mergeRightButton.setImage(UIImage(systemName: "arrow.right.to.line.compact"), for: .normal)
            mergeRightButton.tintColor = .secondaryLabel
            mergeRightButton.backgroundColor = .tertiarySystemFill
            mergeRightButton.layer.cornerRadius = 8

            actionMenuStack.addArrangedSubview(mergeLeftButton)
            actionMenuStack.addArrangedSubview(splitButton)
            actionMenuStack.addArrangedSubview(mergeRightButton)

            let actionMenuOuterStack = UIStackView(arrangedSubviews: [wordActionsStack, actionMenuStack])
            actionMenuOuterStack.translatesAutoresizingMaskIntoConstraints = false
            actionMenuOuterStack.axis = .vertical
            actionMenuOuterStack.spacing = 8
            actionMenuOuterStack.alignment = .fill

            actionMenuContainer.addSubview(actionMenuOuterStack)
            NSLayoutConstraint.activate([
                actionMenuOuterStack.topAnchor.constraint(equalTo: actionMenuContainer.topAnchor, constant: 6),
                actionMenuOuterStack.leadingAnchor.constraint(equalTo: actionMenuContainer.leadingAnchor, constant: 6),
                actionMenuOuterStack.trailingAnchor.constraint(equalTo: actionMenuContainer.trailingAnchor, constant: -6),
                actionMenuOuterStack.bottomAnchor.constraint(equalTo: actionMenuContainer.bottomAnchor, constant: -6),
                wordActionsStack.heightAnchor.constraint(equalToConstant: 44),
                actionMenuStack.heightAnchor.constraint(equalToConstant: 44),
            ])

            var currentLeftNeighborSurface = leftNeighborSurface
            var currentRightNeighborSurface = rightNeighborSurface
            var currentOnSelectPrevious = onSelectPrevious
            var currentOnSelectNext = onSelectNext
            var currentOnMergeLeft = onMergeLeft
            var currentOnMergeRight = onMergeRight
            var currentOnSplitApply = onSplitApply
            var leftSplitValue = ""
            var rightSplitValue = ""
            var splitEntryLeftValue = ""
            var splitEntryRightValue = ""
            var isSplitEditorVisible = false
            var currentSheetPreferredHeight: CGFloat = 0

            // Returns the current split boundary as a UTF-16 offset derived from the left split value.
            func splitOffsetUTF16() -> Int {
                leftSplitValue.utf16.count
            }

            // Measures actual rendered component sizes to derive the ideal sheet height without mirroring section logic.
            func computePreferredSheetHeight() -> CGFloat {
                let contentWidth = max(200, self.activeScreenBounds().width) - 32
                let middleHeight = ceil(middleContentStack.systemLayoutSizeFitting(
                    CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height)
                // splitPanelContainer uses a height == 0 constraint when collapsed, so its fitted height is 0 when hidden.
                let splitHeight = ceil(splitPanelContainer.systemLayoutSizeFitting(
                    CGSize(width: contentWidth, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height)
                // Chrome covers grabber (20), top safe-area (~59), nav row (~56), split gap (8+0),
                // middle top spacing (16), action bar (two rows: 44+8+44+12=108 container + 12 margin),
                // bottom safe-area (~34), plus margins.
                let safeArea = self.topPresentingController().flatMap { $0.view.window?.safeAreaInsets } ?? .zero
                let baseChrome: CGFloat = 20 + safeArea.top + 56 + 8 + 16 + 108 + 12 + safeArea.bottom + 16
                return baseChrome + middleHeight + splitHeight
            }

            // Recalculates and applies the preferred sheet height for the current surface and split-editor visibility state.
            func updateSheetPreferredHeight(animated: Bool) {
                _ = animated
                currentSheetPreferredHeight = computePreferredSheetHeight()

                guard let sheetPresentationController = sheetController.sheetPresentationController else {
                    return
                }

                if #available(iOS 16.0, *) {
                    sheetPresentationController.invalidateDetents()
                }
            }

            // Shows or hides the split editor panel and updates button tint and sheet height accordingly.
            func setSplitEditorVisible(_ visible: Bool) {
                isSplitEditorVisible = visible
                splitPanelContainer.isHidden = !visible
                splitPanelCollapsedConstraint.isActive = !visible
                splitButton.tintColor = visible ? .label : .secondaryLabel
                updateSheetPreferredHeight(animated: true)
            }

            // Reflects current neighbor availability in merge button enabled state and opacity.
            func updateMergeButtonAvailability() {
                mergeLeftButton.isEnabled = currentLeftNeighborSurface != nil
                mergeLeftButton.alpha = currentLeftNeighborSurface == nil ? 0.45 : 1
                mergeRightButton.isEnabled = currentRightNeighborSurface != nil
                mergeRightButton.alpha = currentRightNeighborSurface == nil ? 0.45 : 1
            }

            // Applies a merge or split outcome to local state and refreshes the surface label and button availability.
            func updateCurrentSurface(_ outcome: (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)) {
                currentSurface = outcome.surface
                currentLeftNeighborSurface = outcome.leftNeighborSurface
                currentRightNeighborSurface = outcome.rightNeighborSurface
                // Rebuild the header row with per-run furigana for the new surface.
                let updatedReading = self.currentSheetUniqueReadings.first ?? ""
                headerRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
                for view in buildHeaderSubviews(surface: currentSurface, reading: updatedReading) {
                    headerRow.addArrangedSubview(view)
                }
                syncFuriganaToCurrentIndex()
                splitButton.isEnabled = currentSurface.count > 1
                splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
                updateMergeButtonAvailability()
            }

            // Converts frequency data to a unified Zipf-equivalent score (higher = more frequent).
            // jpdbRank is preferred; wordfreqZipf used as fallback. Both land on a ~0–7 scale.
            func normalizedScore(_ data: [String: FrequencyData]) -> Double? {
                if let rank = data.values.compactMap({ $0.jpdbRank }).min() {
                    return max(0.0, 7.0 - log10(Double(rank)))
                }
                return data.values.compactMap({ $0.wordfreqZipf }).max()
            }

            // Resets left and right split values using the highest-scoring two-segment sublattice path,
            // falling back to a midpoint split when no two-segment path exists.
            func resetSplitInputs(using outcomeSurface: String) {
                // Returns a normalized frequency score for one segment, defaulting to 0 when unscored.
                func segmentScore(_ segment: String) -> Double {
                    self.pathSegmentFrequencyProvider?(segment).flatMap { normalizedScore($0) } ?? 0
                }

                func pathScore(_ path: [String]) -> Double {
                    path.map(segmentScore).reduce(0, +) / max(1, Double(path.count))
                }

                let twoPaths = self.sublatticeValidPaths(from: self.currentSheetSublatticeEdges)
                    .filter { $0.count == 2 }

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

            // Vertical stack between the surface title and the bottom action menu — add content here.
            let middleContentStack = UIStackView()
            middleContentStack.translatesAutoresizingMaskIntoConstraints = false
            middleContentStack.axis = .vertical
            middleContentStack.spacing = 12
            middleContentStack.alignment = .fill

            // Builds a small section header label.
            func makeSectionHeader(_ text: String) -> UILabel {
                let label = UILabel()
                label.text = text.uppercased()
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .tertiaryLabel
                return label
            }

            // Builds a body label for multi-line debug content.
            func makeBodyLabel(_ text: String) -> UILabel {
                let label = UILabel()
                label.text = text
                label.numberOfLines = 0
                label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                label.textColor = .secondaryLabel
                return label
            }

            // Rebuilds middleContentStack — shows sublattice paths with scores, then dictionary definitions.
            func updateMiddleContent() {
                for subview in middleContentStack.arrangedSubviews {
                    middleContentStack.removeArrangedSubview(subview)
                    subview.removeFromSuperview()
                }

                // Sublattice paths with normalized frequency scores, sorted best-first.
                let sublatticeEdges = self.currentSheetSublatticeEdges
                if sublatticeEdges.isEmpty == false {
                    func segmentScore(_ segment: String) -> Double {
                        self.pathSegmentFrequencyProvider?(segment).flatMap { normalizedScore($0) } ?? 0
                    }
                    let paths = self.sublatticeValidPaths(from: sublatticeEdges)
                        .sorted { lhs, rhs in
                            let lScore = lhs.map(segmentScore).reduce(0, +) / max(1, Double(lhs.count))
                            let rScore = rhs.map(segmentScore).reduce(0, +) / max(1, Double(rhs.count))
                            return lScore > rScore
                        }
                    if paths.isEmpty == false {
                        middleContentStack.addArrangedSubview(makeSectionHeader("Paths"))
                        let pathLines = paths.map { path -> String in
                            let score = path.map(segmentScore).reduce(0, +) / max(1, Double(path.count))
                            return path.joined(separator: " · ") + "  [\(String(format: "%.2f", score))]"
                        }.joined(separator: "\n")
                        middleContentStack.addArrangedSubview(makeBodyLabel(pathLines))
                    }
                }

                guard let displayData = self.currentSheetWordDisplayData else { return }
                let senses = displayData.entry.senses
                guard senses.isEmpty == false else { return }

                for (index, sense) in senses.enumerated() {
                    let glossText = sense.glosses.joined(separator: "; ")
                    guard glossText.isEmpty == false else { continue }

                    let row = UIStackView()
                    row.axis = .horizontal
                    row.spacing = 8
                    row.alignment = .firstBaseline

                    let numberLabel = UILabel()
                    numberLabel.text = "\(index + 1)."
                    numberLabel.font = .systemFont(ofSize: 14, weight: .medium)
                    numberLabel.textColor = .tertiaryLabel
                    numberLabel.setContentHuggingPriority(.required, for: .horizontal)
                    numberLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

                    let glossLabel = UILabel()
                    glossLabel.text = glossText
                    glossLabel.font = .systemFont(ofSize: 15)
                    glossLabel.textColor = .label
                    glossLabel.numberOfLines = 0

                    row.addArrangedSubview(numberLabel)
                    row.addArrangedSubview(glossLabel)
                    middleContentStack.addArrangedSubview(row)
                }
            }

            // Speaks the current surface using the device TTS engine with a Japanese voice.
            speakButton.addAction(
                UIAction { [weak speakButton] _ in
                    let synthesizer = AVSpeechSynthesizer()
                    // Associate synthesizer lifetime with the button so it lives long enough to finish speaking.
                    objc_setAssociatedObject(speakButton as Any, &SegmentLookupSheet.speechSynthesizerKey, synthesizer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                    let utterance = AVSpeechUtterance(string: currentSurface)
                    utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
                    synthesizer.speak(utterance)
                },
                for: .touchUpInside
            )

            // Toggles saved state and refreshes the save button appearance.
            saveButton.addAction(
                UIAction { _ in
                    self.sheetSaveToggle?()
                    updateSaveButtonAppearance()
                },
                for: .touchUpInside
            )

            // Dismisses the sheet and opens WordDetailView for the current segment.
            openDetailButton.addAction(
                UIAction { _ in
                    self.sheetOpenWordDetail?()
                },
                for: .touchUpInside
            )

            // Register reading navigation actions here so updateMiddleContent is already in scope.
            prevReadingButton.addAction(
                UIAction { _ in
                    let total = totalSlots()
                    guard total > 1 else { return }
                    currentReadingIndex = (currentReadingIndex - 1 + total) % total
                    syncFuriganaToCurrentIndex()
                    applyCurrentReadingSelection()
                    updateMiddleContent()
                },
                for: .touchUpInside
            )

            nextReadingButton.addAction(
                UIAction { _ in
                    let total = totalSlots()
                    guard total > 1 else { return }
                    currentReadingIndex = (currentReadingIndex + 1) % total
                    syncFuriganaToCurrentIndex()
                    applyCurrentReadingSelection()
                    updateMiddleContent()
                },
                for: .touchUpInside
            )

            // Applies the reading at the current index, or clears the override when landing on an empty custom slot.
            func applyCurrentReadingSelection() {
                if isOnCustomSlot() {
                    if let reading = customReading {
                        self.onReadingSelected?(reading)
                    } else {
                        // Custom slot with no entry: remove furigana rather than leaving a stale override.
                        self.onReadingReset?()
                    }
                } else {
                    self.onReadingSelected?(currentReadings[currentReadingIndex])
                }
            }

            // Tap on the header opens a text-entry alert to set a custom reading (kanji only).
            let headerTapHandler = ClosureTarget { [weak sheetController] in
                guard let vc = sheetController, showCustomSlot else { return }
                let alert = UIAlertController(title: "Custom Reading", message: nil, preferredStyle: .alert)
                alert.addTextField { field in
                    field.text = customReading
                    field.placeholder = "e.g. よむ"
                    field.clearButtonMode = .whileEditing
                    field.keyboardType = .default
                    field.autocorrectionType = .no
                    field.spellCheckingType = .no
                }
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Set", style: .default) { _ in
                    let entered = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard entered.isEmpty == false else { return }
                    customReading = entered
                    currentReadingIndex = currentReadings.count
                    syncFuriganaToCurrentIndex()
                    self.onReadingSelected?(entered)
                    // print("[SegmentLookupSheet] custom reading set: \(entered)")
                })
                vc.present(alert, animated: true)
            }
            // headerTapHandler is retained but not wired to a gesture — header is hidden.
            _ = headerTapHandler

            // Populate initial content.
            updateMiddleContent()

            self.onSheetSelectNext = {
                guard isSplitEditorVisible == false, let outcome = currentOnSelectNext?() else {
                    return
                }

                updateCurrentSurface(outcome)
                // Keeps underlying read-surface overlays stable while swiping between segments.
                updateSheetPreferredHeight(animated: false)
                self.refreshSheetSupplementalData()
                updateReadingFurigana()
                updateLemmaChain()
                updateMiddleContent()
                updateSaveButtonAppearance()
            }

            self.onSheetSelectPrevious = {
                guard isSplitEditorVisible == false, let outcome = currentOnSelectPrevious?() else {
                    return
                }

                updateCurrentSurface(outcome)
                // Keeps underlying read-surface overlays stable while swiping between segments.
                updateSheetPreferredHeight(animated: false)
                self.refreshSheetSupplementalData()
                updateReadingFurigana()
                updateLemmaChain()
                updateMiddleContent()
                updateSaveButtonAppearance()
            }

            self.updatePresentedSheetSelection = {
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
                updatedOnDismiss in
                currentOnSelectPrevious = updatedOnSelectPrevious
                currentOnSelectNext = updatedOnSelectNext
                currentOnMergeLeft = updatedOnMergeLeft
                currentOnMergeRight = updatedOnMergeRight
                currentOnSplitApply = updatedOnSplitApply
                self.sheetReadingsProvider = updatedSheetReadingsProvider
                self.sheetSublatticeProvider = updatedSheetSublatticeProvider
                self.segmentRangeProvider = updatedSegmentRangeProvider
                self.sheetLexiconDebugProvider = updatedSheetLexiconDebugProvider
                self.sheetFrequencyProvider = updatedSheetFrequencyProvider
                self.onDismiss = updatedOnDismiss

                if isSplitEditorVisible {
                    setSplitEditorVisible(false)
                }

                updateCurrentSurface((
                    surface: updatedSurface,
                    leftNeighborSurface: updatedLeftNeighborSurface,
                    rightNeighborSurface: updatedRightNeighborSurface
                ))
                updateSheetPreferredHeight(animated: true)
                self.refreshSheetSupplementalData()
                updateReadingFurigana()
                updateLemmaChain()
                updateMiddleContent()
                updateSaveButtonAppearance()
            }

            let swipeLeftGesture = UISwipeGestureRecognizer(target: self, action: #selector(handleSheetSwipe(_:)))
            swipeLeftGesture.direction = .left
            sheetController.view.addGestureRecognizer(swipeLeftGesture)

            let swipeRightGesture = UISwipeGestureRecognizer(target: self, action: #selector(handleSheetSwipe(_:)))
            swipeRightGesture.direction = .right
            sheetController.view.addGestureRecognizer(swipeRightGesture)

            mergeLeftButton.addAction(
                UIAction { _ in
                    if let mergeResult = currentOnMergeLeft?() {
                        updateCurrentSurface(mergeResult)
                    } else if let leftNeighbor = currentLeftNeighborSurface {
                        currentSurface = leftNeighbor + currentSurface
                        currentLeftNeighborSurface = nil
                        syncFuriganaToCurrentIndex()
                    } else {
                        return
                    }

                    splitButton.isEnabled = currentSurface.count > 1
                    splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
                    updateMergeButtonAvailability()
                    if isSplitEditorVisible {
                        resetSplitInputs(using: currentSurface)
                    }
                    self.refreshSheetSupplementalData()
                    updateReadingFurigana()
                    updateLemmaChain()
                    updateMiddleContent()
                    updateSheetPreferredHeight(animated: true)
                },
                for: .touchUpInside
            )

            mergeRightButton.addAction(
                UIAction { _ in
                    if let mergeResult = currentOnMergeRight?() {
                        updateCurrentSurface(mergeResult)
                    } else if let rightNeighbor = currentRightNeighborSurface {
                        currentSurface = currentSurface + rightNeighbor
                        currentRightNeighborSurface = nil
                        syncFuriganaToCurrentIndex()
                    } else {
                        return
                    }

                    splitButton.isEnabled = currentSurface.count > 1
                    splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
                    updateMergeButtonAvailability()
                    if isSplitEditorVisible {
                        resetSplitInputs(using: currentSurface)
                    }
                    self.refreshSheetSupplementalData()
                    updateReadingFurigana()
                    updateLemmaChain()
                    updateMiddleContent()
                    updateSheetPreferredHeight(animated: true)
                },
                for: .touchUpInside
            )

            splitButton.addAction(
                UIAction { _ in
                    let characters = Array(currentSurface)
                    if characters.count <= 1 {
                        return
                    }

                    if characters.count == 2 {
                        let offset = String(characters[0]).utf16.count
                        if let splitResult = currentOnSplitApply?(offset) {
                            updateCurrentSurface(splitResult)
                            self.refreshSheetSupplementalData()
                            updateReadingFurigana()
                            updateLemmaChain()
                            updateMiddleContent()
                            updateSheetPreferredHeight(animated: true)
                        }
                        return
                    }

                    setSplitEditorVisible(true)
                    resetSplitInputs(using: currentSurface)
                    splitEntryLeftValue = leftSplitValue
                    splitEntryRightValue = rightSplitValue
                },
                for: .touchUpInside
            )

            leftInputTapButton.addAction(
                UIAction { _ in
                    guard rightSplitValue.count > 1 else {
                        return
                    }

                    guard let movedCharacter = rightSplitValue.first else {
                        return
                    }

                    rightSplitValue.removeFirst()
                    leftSplitValue.append(movedCharacter)
                    leftInput.text = leftSplitValue
                    rightInput.text = rightSplitValue
                    let isSplitValid = leftSplitValue.isEmpty == false && rightSplitValue.isEmpty == false
                    applySplitButton.isEnabled = isSplitValid
                    applySplitButton.alpha = applySplitButton.isEnabled ? 1 : 0.5
                    leftInputTapButton.isEnabled = rightSplitValue.count > 1
                    leftInputTapButton.alpha = leftInputTapButton.isEnabled ? 1 : 0.45
                    rightInputTapButton.isEnabled = leftSplitValue.isEmpty == false
                    rightInputTapButton.alpha = rightInputTapButton.isEnabled ? 1 : 0.45
                },
                for: .touchUpInside
            )

            rightInputTapButton.addAction(
                UIAction { _ in
                    guard leftSplitValue.count > 1 else {
                        return
                    }

                    guard let movedCharacter = leftSplitValue.last else {
                        return
                    }

                    leftSplitValue.removeLast()
                    rightSplitValue = String(movedCharacter) + rightSplitValue
                    leftInput.text = leftSplitValue
                    rightInput.text = rightSplitValue
                    let isSplitValid = leftSplitValue.isEmpty == false && rightSplitValue.isEmpty == false
                    applySplitButton.isEnabled = isSplitValid
                    applySplitButton.alpha = applySplitButton.isEnabled ? 1 : 0.5
                    leftInputTapButton.isEnabled = rightSplitValue.isEmpty == false
                    leftInputTapButton.alpha = leftInputTapButton.isEnabled ? 1 : 0.45
                    rightInputTapButton.isEnabled = leftSplitValue.count > 1
                    rightInputTapButton.alpha = rightInputTapButton.isEnabled ? 1 : 0.45
                },
                for: .touchUpInside
            )

            cancelSplitButton.addAction(
                UIAction { _ in
                    leftSplitValue = splitEntryLeftValue
                    rightSplitValue = splitEntryRightValue
                    leftInput.text = leftSplitValue
                    rightInput.text = rightSplitValue
                    setSplitEditorVisible(false)
                },
                for: .touchUpInside
            )

            applySplitButton.addAction(
                UIAction { _ in
                    let splitOffset = splitOffsetUTF16()
                    if let splitResult = currentOnSplitApply?(splitOffset) {
                        updateCurrentSurface(splitResult)
                    } else {
                        currentSurface = leftSplitValue + rightSplitValue
                        syncFuriganaToCurrentIndex()
                    }

                    splitButton.isEnabled = currentSurface.count > 1
                    splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
                    updateMergeButtonAvailability()
                    setSplitEditorVisible(false)
                    self.refreshSheetSupplementalData()
                    updateReadingFurigana()
                    updateLemmaChain()
                    updateMiddleContent()
                    updateSheetPreferredHeight(animated: true)
                },
                for: .touchUpInside
            )

            splitButton.isEnabled = currentSurface.count > 1
            splitButton.alpha = splitButton.isEnabled ? 1 : 0.45

            updateMergeButtonAvailability()

            // segmentRangeProvider() returns the NSRange of the current segment within the note.
            // Add content to middleContentStack here using that range as needed.

            sheetController.view.addSubview(headerStack)
            sheetController.view.addSubview(splitPanelContainer)
            sheetController.view.addSubview(middleContentStack)
            sheetController.view.addSubview(actionMenuContainer)

            updateReadingFurigana()
            updateLemmaChain()

            NSLayoutConstraint.activate([
                // Surface header with furigana at the top of the sheet.
                headerStack.topAnchor.constraint(equalTo: sheetController.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                headerStack.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                headerStack.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),


                splitPanelContainer.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
                splitPanelContainer.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                splitPanelContainer.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),

                middleContentStack.topAnchor.constraint(equalTo: splitPanelContainer.bottomAnchor, constant: 16),
                middleContentStack.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                middleContentStack.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),
                middleContentStack.bottomAnchor.constraint(lessThanOrEqualTo: actionMenuContainer.topAnchor, constant: -12),

                actionMenuContainer.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                actionMenuContainer.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),
                actionMenuContainer.bottomAnchor.constraint(equalTo: sheetController.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            ])

            // Measure initial height from actual content now that constraints and content are established.
            currentSheetPreferredHeight = computePreferredSheetHeight()

            sheetController.modalPresentationStyle = .pageSheet
            sheetController.presentationController?.delegate = self
            if let sheetPresentationController = sheetController.sheetPresentationController {
                if #available(iOS 16.0, *) {
                    let fittedDetentIdentifier = UISheetPresentationController.Detent.Identifier("surfaceFitted")
                    let fittedDetent = UISheetPresentationController.Detent.custom(identifier: fittedDetentIdentifier) { context in
                        // Cap at half the available screen height so the sheet never dominates the reading surface.
                        let halfScreen = context.maximumDetentValue * 0.5
                        return min(currentSheetPreferredHeight, halfScreen)
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

            presenter.present(sheetController, animated: false)
            self.presentedSheetController = sheetController
        }
    }

    // Refreshes hidden per-selection sheet metadata for future UI usage.
}
