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
        // Capture the reading callback before dismissPopover, since dismissSheet clears it.
        let capturedOnReadingSelected = self.onReadingSelected
        dismissPopover(notifyDismissal: false) { [weak self] in
            guard let self, let presenter = self.topPresentingController() else {
                return
            }

            self.onDismiss = onDismiss
            self.onReadingSelected = capturedOnReadingSelected
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

            let readingSubtitleLabel = UILabel()
            readingSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            readingSubtitleLabel.textColor = .secondaryLabel
            readingSubtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
            readingSubtitleLabel.textAlignment = .center
            readingSubtitleLabel.numberOfLines = 1

            let surfaceStack = UIStackView(arrangedSubviews: [surfaceLabel, readingSubtitleLabel])
            surfaceStack.translatesAutoresizingMaskIntoConstraints = false
            surfaceStack.axis = .vertical
            surfaceStack.alignment = .center
            surfaceStack.spacing = 2

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

            var currentReadingIndex = 0
            var currentReadings: [String] = self.currentSheetUniqueReadings

            // Refreshes arrow visibility and reading subtitle for the current readings list.
            func updateReadingFurigana() {
                currentReadings = self.currentSheetUniqueReadings
                currentReadingIndex = 0
                let reading = currentReadings.first
                readingSubtitleLabel.text = reading
                readingSubtitleLabel.isHidden = reading == nil || reading?.isEmpty == true
                print("[SegmentLookupSheet] updateReadingFurigana: surface=\(currentSurface) readings=\(currentReadings) reading=\(reading ?? "nil")")
                let hasMultiple = currentReadings.count > 1
                prevReadingButton.isHidden = !hasMultiple
                nextReadingButton.isHidden = !hasMultiple
            }

            NSLayoutConstraint.activate([
                prevReadingButton.widthAnchor.constraint(equalToConstant: 32),
                prevReadingButton.heightAnchor.constraint(equalToConstant: 32),
                nextReadingButton.widthAnchor.constraint(equalToConstant: 32),
                nextReadingButton.heightAnchor.constraint(equalToConstant: 32),
            ])

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

            // Resets left and right split values to a midpoint split of the given surface so the editor starts in a sensible state.
            func resetSplitInputs(using outcomeSurface: String) {
                let characters = Array(outcomeSurface)
                if characters.count <= 1 {
                    leftSplitValue = outcomeSurface
                    rightSplitValue = ""
                } else {
                    let midpoint = characters.count / 2
                    leftSplitValue = String(characters[0..<midpoint])
                    rightSplitValue = String(characters[midpoint..<characters.count])
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

                // Section 1: Readings annotated with per-reading frequency data.
                let readings = self.currentSheetUniqueReadings
                if readings.isEmpty == false {
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

                // Section 3: Valid segmentation paths through the sublattice DAG
                let sublatticeEdges = self.currentSheetSublatticeEdges
                if sublatticeEdges.isEmpty == false {
                    let paths = self.sublatticeValidPaths(from: sublatticeEdges).reversed()
                    if paths.isEmpty == false {
                        middleContentStack.addArrangedSubview(makeSectionHeader("Paths"))
                        let pathLines = paths.map { $0.joined(separator: " · ") }.joined(separator: "\n")
                        middleContentStack.addArrangedSubview(makeBodyLabel(pathLines))
                    }
                }

                // Section 4: Lexicon method debug dump
                let debugInfo = self.currentSheetLexiconDebugInfo
                if debugInfo.isEmpty == false {
                    middleContentStack.addArrangedSubview(makeSectionHeader("Lexicon"))
                    middleContentStack.addArrangedSubview(makeBodyLabel(debugInfo))
                }
            }

            // Register reading navigation actions here so updateMiddleContent is already in scope.
            prevReadingButton.addAction(
                UIAction { _ in
                    print("[SegmentLookupSheet] prevReadingButton tapped: count=\(currentReadings.count) index=\(currentReadingIndex)")
                    guard currentReadings.count > 1 else { return }
                    currentReadingIndex = (currentReadingIndex - 1 + currentReadings.count) % currentReadings.count
                    let reading = currentReadings[currentReadingIndex]
                    readingSubtitleLabel.text = reading
                    print("[SegmentLookupSheet] prev: now showing reading=\(reading) at index=\(currentReadingIndex)")
                    self.onReadingSelected?(reading)
                    updateMiddleContent()
                },
                for: .touchUpInside
            )

            nextReadingButton.addAction(
                UIAction { _ in
                    print("[SegmentLookupSheet] nextReadingButton tapped: count=\(currentReadings.count) index=\(currentReadingIndex)")
                    guard currentReadings.count > 1 else { return }
                    currentReadingIndex = (currentReadingIndex + 1) % currentReadings.count
                    let reading = currentReadings[currentReadingIndex]
                    readingSubtitleLabel.text = reading
                    print("[SegmentLookupSheet] next: now showing reading=\(reading) at index=\(currentReadingIndex)")
                    self.onReadingSelected?(reading)
                    updateMiddleContent()
                },
                for: .touchUpInside
            )

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
                            updateMiddleContent()
                            updateReadingFurigana()
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
            sheetController.view.addSubview(splitPanelContainer)
            sheetController.view.addSubview(middleContentStack)
            sheetController.view.addSubview(actionMenuContainer)

            updateReadingFurigana()

            NSLayoutConstraint.activate([
                readingNavRow.topAnchor.constraint(equalTo: sheetController.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                readingNavRow.centerXAnchor.constraint(equalTo: sheetController.view.centerXAnchor),
                readingNavRow.leadingAnchor.constraint(greaterThanOrEqualTo: sheetController.view.leadingAnchor, constant: 16),
                readingNavRow.trailingAnchor.constraint(lessThanOrEqualTo: sheetController.view.trailingAnchor, constant: -16),

                splitPanelContainer.topAnchor.constraint(equalTo: readingNavRow.bottomAnchor, constant: 12),
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
                    sheetPresentationController.detents = [fittedDetent]
                    sheetPresentationController.selectedDetentIdentifier = fittedDetentIdentifier
                    sheetPresentationController.largestUndimmedDetentIdentifier = fittedDetentIdentifier
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
    func refreshSheetSupplementalData() {
        currentSheetUniqueReadings = sheetReadingsProvider?() ?? []
        currentSheetSublatticeEdges = sheetSublatticeProvider?() ?? []
        currentSheetLexiconDebugInfo = sheetLexiconDebugProvider?() ?? ""
        currentSheetFrequencyByReading = sheetFrequencyProvider?()
    }

    // Delivers and clears one-shot dismissal callback used by the read view to clear selection state.
    func fireOnDismissIfNeeded() {
        guard let onDismiss else {
            return
        }

        self.onDismiss = nil
        onDismiss()
    }

    // Routes horizontal sheet swipe gestures to the current selection-navigation callbacks.
    @objc func handleSheetSwipe(_ gestureRecognizer: UISwipeGestureRecognizer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            switch gestureRecognizer.direction {
                case .left: onSheetSelectNext?()
                case .right: onSheetSelectPrevious?()
                default: break
            }
        }
        CATransaction.commit()
    }

    // Generates initial left and right segment groups for split mode from the tapped surface text.
    func initialSplitSegments(for surface: String) -> (left: [String], right: [String]) {
        let allSegments = segmentizeSurface(surface)
        if allSegments.isEmpty {
            return (left: [surface], right: [])
        }

        if allSegments.count == 1 {
            return (left: [allSegments[0]], right: [])
        }

        return (left: [allSegments[0]], right: Array(allSegments.dropFirst()))
    }

    // Splits surface text into segment units for transfer between split inputs.
    func segmentizeSurface(_ surface: String) -> [String] {
        let whitespaceSegments = surface
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        if whitespaceSegments.isEmpty == false {
            return whitespaceSegments
        }

        return surface.map { String($0) }
    }

    // Enumerates all complete paths through the sublattice edge DAG, capped to avoid combinatorial explosion.
    // Paths containing single-kana segments not in the ParticleSettings allowlist are excluded.
    func sublatticeValidPaths(from edges: [LatticeEdge]) -> [[String]] {
        guard edges.isEmpty == false else { return [] }
        guard let startIndex = edges.map({ $0.start }).min(),
              let endIndex = edges.map({ $0.end }).max() else { return [] }

        var edgesByStart: [String.Index: [LatticeEdge]] = [:]
        for edge in edges {
            edgesByStart[edge.start, default: []].append(edge)
        }

        let allowedKana = ParticleSettings.allowed()
        var allPaths: [[String]] = []
        let limit = 24

        func dfs(current: String.Index, path: [String]) {
            if current == endIndex {
                allPaths.append(path)
                return
            }
            if allPaths.count >= limit { return }
            let next = (edgesByStart[current] ?? []).sorted { $0.surface < $1.surface }
            for edge in next {
                if allPaths.count >= limit { return }
                // Reject edges that are single-kana bound morphemes not in the allowlist.
                if edge.surface.count == 1,
                   ScriptClassifier.isPureKana(edge.surface),
                   allowedKana.contains(edge.surface) == false {
                    continue
                }
                dfs(current: edge.end, path: path + [edge.surface])
            }
        }

        dfs(current: startIndex, path: [])
        return allPaths
    }

    // Rebuilds one segment row with tappable chip buttons that transfer segments across split inputs.
    func rebuildSegmentRow(
        _ row: UIStackView,
        segments: [String],
        onSegmentPressed: @escaping (String) -> Void
    ) {
        row.arrangedSubviews.forEach { arrangedSubview in
            row.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        if segments.isEmpty {
            let placeholder = UILabel()
            placeholder.text = "—"
            placeholder.textColor = .tertiaryLabel
            placeholder.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(placeholder)
            return
        }

        for segment in segments {
            let segmentButton = UIButton(type: .system)
            segmentButton.setTitle(segment, for: .normal)
            segmentButton.setTitleColor(.label, for: .normal)
            segmentButton.titleLabel?.font = .systemFont(ofSize: 13)
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            segmentButton.configuration = configuration
            segmentButton.backgroundColor = UIColor.secondarySystemFill
            segmentButton.layer.cornerRadius = 8
            segmentButton.addAction(
                UIAction { _ in
                    onSegmentPressed(segment)
                },
                for: .touchUpInside
            )
            row.addArrangedSubview(segmentButton)
        }
    }
}
