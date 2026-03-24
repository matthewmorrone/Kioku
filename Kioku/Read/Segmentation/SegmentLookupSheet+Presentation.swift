import UIKit

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
        dismissPopover(notifyDismissal: false) { [weak self] in
            guard let self, let presenter = self.topPresentingController() else {
                return
            }

            self.onDismiss = onDismiss
            self.onReadingSelected = capturedOnReadingSelected
            self.pathSegmentFrequencyProvider = capturedPathSegmentFrequencyProvider
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

            let surfaceLabel = CopyableLabel()
            surfaceLabel.translatesAutoresizingMaskIntoConstraints = false
            surfaceLabel.textColor = .label
            surfaceLabel.font = .systemFont(ofSize: 20, weight: .semibold)
            surfaceLabel.textAlignment = .center
            surfaceLabel.numberOfLines = 0
            surfaceLabel.text = surface

            // Using UIButton instead of UILabel so the custom-reading slot is directly tappable.
            let readingSubtitleLabel = UIButton(type: .system)
            readingSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            readingSubtitleLabel.setTitleColor(.secondaryLabel, for: .normal)
            readingSubtitleLabel.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
            readingSubtitleLabel.contentHorizontalAlignment = .center
            readingSubtitleLabel.isUserInteractionEnabled = false

            let surfaceStack = UIStackView(arrangedSubviews: [surfaceLabel, readingSubtitleLabel])
            surfaceStack.translatesAutoresizingMaskIntoConstraints = false
            surfaceStack.axis = .vertical
            surfaceStack.alignment = .center
            surfaceStack.spacing = 3

            let prevReadingButton = UIButton(type: .system)
            prevReadingButton.translatesAutoresizingMaskIntoConstraints = false
            prevReadingButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            prevReadingButton.tintColor = .tertiaryLabel

            let nextReadingButton = UIButton(type: .system)
            nextReadingButton.translatesAutoresizingMaskIntoConstraints = false
            nextReadingButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
            nextReadingButton.tintColor = .tertiaryLabel

            let readingNavRow = UIStackView(arrangedSubviews: [prevReadingButton, surfaceStack, nextReadingButton])
            readingNavRow.translatesAutoresizingMaskIntoConstraints = false
            readingNavRow.axis = .horizontal
            readingNavRow.alignment = .center
            readingNavRow.spacing = 8

            // Shows the inflection chain — 食べた → 食べる — between the header and the split panel.
            let lemmaChainLabel = UILabel()
            lemmaChainLabel.translatesAutoresizingMaskIntoConstraints = false
            lemmaChainLabel.font = .systemFont(ofSize: 13)
            lemmaChainLabel.textColor = .secondaryLabel
            lemmaChainLabel.textAlignment = .center
            lemmaChainLabel.numberOfLines = 1
            lemmaChainLabel.isHidden = true

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

            // Updates the subtitle button text, color, tappability, and reset button visibility for the current index.
            // Pure-kana surfaces have no distinct reading to display; hide the subtitle entirely for them.
            func syncSubtitleToCurrentIndex() {
                guard showCustomSlot || isOnCustomSlot() else {
                    readingSubtitleLabel.isHidden = true
                    readingSubtitleLabel.isUserInteractionEnabled = false
                    return
                }
                if isOnCustomSlot() {
                    let title = customReading ?? "Custom…"
                    let color: UIColor = customReading != nil ? .secondaryLabel : .tertiaryLabel
                    readingSubtitleLabel.setTitle(title, for: .normal)
                    readingSubtitleLabel.setTitleColor(color, for: .normal)
                    readingSubtitleLabel.isHidden = false
                    readingSubtitleLabel.isUserInteractionEnabled = true
                } else {
                    let reading = currentReadings[currentReadingIndex]
                    readingSubtitleLabel.setTitle(reading.isEmpty ? nil : reading, for: .normal)
                    readingSubtitleLabel.setTitleColor(.secondaryLabel, for: .normal)
                    readingSubtitleLabel.isHidden = false
                    // Kanji segments with a single reading have no navigation arrows, so make the
                    // subtitle tappable directly to allow setting a custom reading.
                    let isSingleReadingKanji = showCustomSlot && currentReadings.count <= 1
                    readingSubtitleLabel.isUserInteractionEnabled = isSingleReadingKanji
                }
            }

            // Refreshes arrow/custom visibility and reading subtitle for the current segment surface.
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

                let reading = currentReadings.first
                print("[SegmentLookupSheet] updateReadingFurigana: surface=\(currentSurface) readings=\(currentReadings) reading=\(reading ?? "nil")")
                syncSubtitleToCurrentIndex()
                // Show arrows only for kanji segments with more than one reading candidate.
                let hasMultiple = showCustomSlot && currentReadings.count > 1
                prevReadingButton.isHidden = !hasMultiple
                nextReadingButton.isHidden = !hasMultiple
            }

            NSLayoutConstraint.activate([
                prevReadingButton.widthAnchor.constraint(equalToConstant: 32),
                prevReadingButton.heightAnchor.constraint(equalToConstant: 32),
                nextReadingButton.widthAnchor.constraint(equalToConstant: 32),
                nextReadingButton.heightAnchor.constraint(equalToConstant: 32),
            ])

            // Updates the lemma chain label shown between the header and the split panel.
            func updateLemmaChain() {
                if let info = self.currentSheetLemmaInfo, info.lemma != currentSurface {
                    let parts = [currentSurface] + info.chain + [info.lemma]
                    lemmaChainLabel.text = parts.joined(separator: " → ")
                    lemmaChainLabel.isHidden = false
                } else {
                    lemmaChainLabel.isHidden = true
                }
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

            let saveButton = UIButton(type: .system)
            saveButton.translatesAutoresizingMaskIntoConstraints = false
            saveButton.backgroundColor = .tertiarySystemFill
            saveButton.layer.cornerRadius = 8

            // Syncs bookmark icon and tint with current saved state.
            func updateSaveButton() {
                let isSaved = self.sheetIsSavedProvider?() ?? false
                saveButton.setImage(UIImage(systemName: isSaved ? "bookmark.fill" : "bookmark"), for: .normal)
                saveButton.tintColor = isSaved ? .systemBlue : .secondaryLabel
            }

            saveButton.addAction(UIAction { [weak self] _ in
                self?.sheetSaveToggle?()
                updateSaveButton()
            }, for: .touchUpInside)

            actionMenuStack.addArrangedSubview(saveButton)
            actionMenuStack.addArrangedSubview(mergeLeftButton)
            actionMenuStack.addArrangedSubview(splitButton)
            actionMenuStack.addArrangedSubview(mergeRightButton)

            actionMenuContainer.addSubview(actionMenuStack)
            NSLayoutConstraint.activate([
                actionMenuStack.topAnchor.constraint(equalTo: actionMenuContainer.topAnchor, constant: 6),
                actionMenuStack.leadingAnchor.constraint(equalTo: actionMenuContainer.leadingAnchor, constant: 6),
                actionMenuStack.trailingAnchor.constraint(equalTo: actionMenuContainer.trailingAnchor, constant: -6),
                actionMenuStack.bottomAnchor.constraint(equalTo: actionMenuContainer.bottomAnchor, constant: -6),
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
            var definitionsExpanded = false
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
                // Chrome covers grabber, top safe-area inset, nav row, subtitle, all fixed spacings, action bar, bottom safe area.
                let baseChrome: CGFloat = 210
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
                surfaceLabel.text = currentSurface
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

                let twoPaths = self.sublatticeValidPaths(from: self.currentSheetSublatticeEdges)
                    .filter { $0.count == 2 }

                if let best = twoPaths.max(by: {
                    ($0.map(segmentScore).reduce(0, +) / 2) < ($1.map(segmentScore).reduce(0, +) / 2)
                }) {
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

            // Rebuilds middleContentStack with four sections: frequency, readings, sublattice+paths, lexicon dump.
            func updateMiddleContent() {
                for subview in middleContentStack.arrangedSubviews {
                    middleContentStack.removeArrangedSubview(subview)
                    subview.removeFromSuperview()
                }

                // Section: Definitions — first sense shown by default, rest expandable.
                if let entry = self.currentSheetWordDisplayData?.entry, entry.senses.isEmpty == false {
                    middleContentStack.addArrangedSubview(makeSectionHeader("Definition"))
                    let shown = definitionsExpanded ? entry.senses : Array(entry.senses.prefix(1))
                    for (idx, sense) in shown.enumerated() {
                        middleContentStack.addArrangedSubview(makeBodyLabel("\(idx + 1). \(self.formatSense(sense))"))
                    }
                    if entry.senses.count > 1 {
                        let toggleBtn = UIButton(type: .system)
                        toggleBtn.titleLabel?.font = .systemFont(ofSize: 12)
                        let remaining = entry.senses.count - 1
                        toggleBtn.setTitle(definitionsExpanded ? "Show fewer" : "Show \(remaining) more…", for: .normal)
                        toggleBtn.addAction(UIAction { _ in
                            definitionsExpanded.toggle()
                            updateMiddleContent()
                            updateSheetPreferredHeight(animated: true)
                        }, for: .touchUpInside)
                        middleContentStack.addArrangedSubview(toggleBtn)
                    }
                }

                // Section: Components — shown when the surface decomposes into 2+ sub-words.
                let components = self.currentSheetWordComponents
                if components.isEmpty == false {
                    middleContentStack.addArrangedSubview(makeSectionHeader("Components"))
                    let chipRow = UIStackView()
                    chipRow.axis = .horizontal
                    chipRow.spacing = 8
                    chipRow.alignment = .center
                    for component in components {
                        let chip = UIButton(type: .system)
                        var config = UIButton.Configuration.filled()
                        config.title = component.surface
                        config.baseBackgroundColor = UIColor.tertiarySystemFill
                        config.baseForegroundColor = .label
                        config.cornerStyle = .medium
                        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
                        chip.configuration = config
                        let componentSurface = component.surface
                        let componentGloss = component.gloss
                        chip.addAction(UIAction { [weak self, weak sheetController] _ in
                            guard let self, let parentVC = sheetController else { return }
                            self.presentComponentSheet(surface: componentSurface, gloss: componentGloss, from: parentVC)
                        }, for: .touchUpInside)
                        chipRow.addArrangedSubview(chip)
                    }
                    middleContentStack.addArrangedSubview(chipRow)
                }

                // Section 1: Readings annotated with per-reading frequency data.
                // Hidden when there is only one candidate — no choice to present.
                let readings = self.currentSheetUniqueReadings
                if readings.count > 1 {
                    middleContentStack.addArrangedSubview(makeSectionHeader("Readings"))
                    let frequencyByReading = self.currentSheetFrequencyByReading
                    let annotatedReadings = readings.map { reading -> String in
                        let data = frequencyByReading?[reading]
                        let rank = data?.jpdbRank.map { "#\($0)" } ?? "—"
                        let zipf = data?.wordfreqZipf.map { String(format: "%.2f", $0) } ?? "—"
                        return "\(reading)  \(rank)  \(zipf)"
                    }
                    middleContentStack.addArrangedSubview(makeBodyLabel(annotatedReadings.joined(separator: "\n")))
                }

                // Section: Best segmentation path — shows only the highest-scoring multi-segment split.
                let sublatticeEdges = self.currentSheetSublatticeEdges
                if sublatticeEdges.isEmpty == false {
                    let paths = self.sublatticeValidPaths(from: sublatticeEdges).filter { $0.count > 1 }
                    // Score each path as the average per-segment frequency; pick the best one.
                    let best = paths.max { lhs, rhs in
                        func avgScore(_ path: [String]) -> Double {
                            let scores = path.compactMap { self.pathSegmentFrequencyProvider?($0).flatMap { normalizedScore($0) } }
                            return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(path.count)
                        }
                        return avgScore(lhs) < avgScore(rhs)
                    }
                    if let best {
                        middleContentStack.addArrangedSubview(makeSectionHeader("Best Split"))
                        var segmentScores: [Double] = []
                        let annotated = best.map { segment -> String in
                            let score: Double? = self.pathSegmentFrequencyProvider?(segment).flatMap { normalizedScore($0) }
                            if let score {
                                segmentScores.append(score)
                                return "\(segment) (\(String(format: "%.1f", score)))"
                            } else {
                                return "\(segment) (-)"
                            }
                        }.joined(separator: " · ")
                        let avg = segmentScores.reduce(0, +) / Double(best.count)
                        middleContentStack.addArrangedSubview(makeBodyLabel("\(annotated)  [\(String(format: "%.1f", avg))]"))
                    }
                }


            }

            // Register reading navigation actions here so updateMiddleContent is already in scope.
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

            prevReadingButton.addAction(
                UIAction { _ in
                    let total = totalSlots()
                    print("[SegmentLookupSheet] prevReadingButton tapped: total=\(total) index=\(currentReadingIndex)")
                    guard total > 1 else { return }
                    currentReadingIndex = (currentReadingIndex - 1 + total) % total
                    syncSubtitleToCurrentIndex()
                    applyCurrentReadingSelection()
                    print("[SegmentLookupSheet] prev: now at index=\(currentReadingIndex) onCustom=\(isOnCustomSlot())")
                    updateMiddleContent()
                },
                for: .touchUpInside
            )

            nextReadingButton.addAction(
                UIAction { _ in
                    let total = totalSlots()
                    print("[SegmentLookupSheet] nextReadingButton tapped: total=\(total) index=\(currentReadingIndex)")
                    guard total > 1 else { return }
                    currentReadingIndex = (currentReadingIndex + 1) % total
                    syncSubtitleToCurrentIndex()
                    applyCurrentReadingSelection()
                    print("[SegmentLookupSheet] next: now at index=\(currentReadingIndex) onCustom=\(isOnCustomSlot())")
                    updateMiddleContent()
                },
                for: .touchUpInside
            )

            // Tap on the subtitle button while on the custom slot opens a text-entry alert.
            readingSubtitleLabel.addAction(UIAction { [weak sheetController] _ in
                guard let vc = sheetController else { return }
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
                    // Ensure we are on the custom slot so syncSubtitleToCurrentIndex shows the custom reading.
                    currentReadingIndex = currentReadings.count
                    syncSubtitleToCurrentIndex()
                    self.onReadingSelected?(entered)
                    print("[SegmentLookupSheet] custom reading set: \(entered)")
                })
                vc.present(alert, animated: true)
            }, for: .touchUpInside)

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
                updateSaveButton()
                updateMiddleContent()
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
                updateSaveButton()
                updateMiddleContent()
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
                updateSaveButton()
                updateMiddleContent()
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
                        surfaceLabel.text = currentSurface
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
                    updateSaveButton()
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
                        surfaceLabel.text = currentSurface
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
                    updateSaveButton()
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
                            updateSaveButton()
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
                        surfaceLabel.text = currentSurface
                    }

                    splitButton.isEnabled = currentSurface.count > 1
                    splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
                    updateMergeButtonAvailability()
                    setSplitEditorVisible(false)
                    self.refreshSheetSupplementalData()
                    updateReadingFurigana()
                    updateLemmaChain()
                    updateSaveButton()
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

            sheetController.view.addSubview(readingNavRow)
            sheetController.view.addSubview(lemmaChainLabel)
            sheetController.view.addSubview(splitPanelContainer)
            sheetController.view.addSubview(middleContentStack)
            sheetController.view.addSubview(actionMenuContainer)

            updateReadingFurigana()
            updateLemmaChain()
            updateSaveButton()

            NSLayoutConstraint.activate([
                readingNavRow.topAnchor.constraint(equalTo: sheetController.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                readingNavRow.centerXAnchor.constraint(equalTo: sheetController.view.centerXAnchor),
                readingNavRow.leadingAnchor.constraint(greaterThanOrEqualTo: sheetController.view.leadingAnchor, constant: 16),
                readingNavRow.trailingAnchor.constraint(lessThanOrEqualTo: sheetController.view.trailingAnchor, constant: -16),

                lemmaChainLabel.topAnchor.constraint(equalTo: readingNavRow.bottomAnchor, constant: 4),
                lemmaChainLabel.centerXAnchor.constraint(equalTo: sheetController.view.centerXAnchor),
                lemmaChainLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sheetController.view.leadingAnchor, constant: 16),
                lemmaChainLabel.trailingAnchor.constraint(lessThanOrEqualTo: sheetController.view.trailingAnchor, constant: -16),

                splitPanelContainer.topAnchor.constraint(equalTo: lemmaChainLabel.bottomAnchor, constant: 8),
                splitPanelContainer.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                splitPanelContainer.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),

                middleContentStack.topAnchor.constraint(equalTo: splitPanelContainer.bottomAnchor, constant: 16),
                middleContentStack.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                middleContentStack.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),
                middleContentStack.bottomAnchor.constraint(lessThanOrEqualTo: actionMenuContainer.topAnchor, constant: -12),

                actionMenuContainer.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                actionMenuContainer.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),
                actionMenuContainer.bottomAnchor.constraint(equalTo: sheetController.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                actionMenuContainer.heightAnchor.constraint(equalToConstant: 46),
            ])

            // Measure initial height from actual content now that constraints and content are established.
            currentSheetPreferredHeight = computePreferredSheetHeight()

            sheetController.modalPresentationStyle = .pageSheet
            sheetController.presentationController?.delegate = self
            if let sheetPresentationController = sheetController.sheetPresentationController {
                if #available(iOS 16.0, *) {
                    let fittedDetentIdentifier = UISheetPresentationController.Detent.Identifier("surfaceFitted")
                    let fittedDetent = UISheetPresentationController.Detent.custom(identifier: fittedDetentIdentifier) { context in
                        min(currentSheetPreferredHeight, context.maximumDetentValue)
                    }
                    sheetPresentationController.detents = [fittedDetent, .large()]
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
