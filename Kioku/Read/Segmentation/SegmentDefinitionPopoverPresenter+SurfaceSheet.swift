import UIKit

extension SegmentDefinitionPopoverPresenter {
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
        onDismiss: (() -> Void)?
    ) {
        dismissPopover(notifyDismissal: false) { [weak self] in
            guard let self, let presenter = self.topPresentingController() else {
                return
            }

            self.onDismiss = onDismiss
            self.onSheetSelectPrevious = nil
            self.onSheetSelectNext = nil
            self.sheetReadingsProvider = sheetReadingsProvider
            self.sheetSublatticeProvider = sheetSublatticeProvider
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

            let splitPanelContainer = UIStackView()
            splitPanelContainer.translatesAutoresizingMaskIntoConstraints = false
            splitPanelContainer.axis = .vertical
            splitPanelContainer.spacing = 14
            splitPanelContainer.isHidden = true

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
            var currentSheetPreferredHeight = self.preferredSurfaceSheetHeight(
                for: currentSurface,
                isSplitEditorVisible: false
            )

            func splitOffsetUTF16() -> Int {
                leftSplitValue.utf16.count
            }

            func updateSheetPreferredHeight(animated: Bool) {
                _ = animated
                currentSheetPreferredHeight = self.preferredSurfaceSheetHeight(
                    for: currentSurface,
                    isSplitEditorVisible: isSplitEditorVisible
                )

                guard let sheetPresentationController = sheetController.sheetPresentationController else {
                    return
                }

                if #available(iOS 16.0, *) {
                    sheetPresentationController.invalidateDetents()
                }
            }

            func setSplitEditorVisible(_ visible: Bool) {
                isSplitEditorVisible = visible
                splitPanelContainer.isHidden = visible == false
                splitButton.tintColor = visible ? .label : .secondaryLabel
                updateSheetPreferredHeight(animated: true)
            }

            func updateMergeButtonAvailability() {
                mergeLeftButton.isEnabled = currentLeftNeighborSurface != nil
                mergeLeftButton.alpha = currentLeftNeighborSurface == nil ? 0.45 : 1
                mergeRightButton.isEnabled = currentRightNeighborSurface != nil
                mergeRightButton.alpha = currentRightNeighborSurface == nil ? 0.45 : 1
            }

            func updateCurrentSurface(_ outcome: (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String?)) {
                currentSurface = outcome.surface
                currentLeftNeighborSurface = outcome.leftNeighborSurface
                currentRightNeighborSurface = outcome.rightNeighborSurface
                surfaceLabel.text = currentSurface
                splitButton.isEnabled = currentSurface.count > 1
                splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
                updateMergeButtonAvailability()
            }

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

            self.onSheetSelectNext = {
                guard isSplitEditorVisible == false, let outcome = currentOnSelectNext?() else {
                    return
                }

                updateCurrentSurface(outcome)
                // Keeps underlying read-surface overlays stable while swiping between segments.
                updateSheetPreferredHeight(animated: false)
                self.refreshSheetSupplementalData()
            }

            self.onSheetSelectPrevious = {
                guard isSplitEditorVisible == false, let outcome = currentOnSelectPrevious?() else {
                    return
                }

                updateCurrentSurface(outcome)
                // Keeps underlying read-surface overlays stable while swiping between segments.
                updateSheetPreferredHeight(animated: false)
                self.refreshSheetSupplementalData()
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
                updatedOnDismiss in
                currentOnSelectPrevious = updatedOnSelectPrevious
                currentOnSelectNext = updatedOnSelectNext
                currentOnMergeLeft = updatedOnMergeLeft
                currentOnMergeRight = updatedOnMergeRight
                currentOnSplitApply = updatedOnSplitApply
                self.sheetReadingsProvider = updatedSheetReadingsProvider
                self.sheetSublatticeProvider = updatedSheetSublatticeProvider
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
                    updateSheetPreferredHeight(animated: true)
                },
                for: .touchUpInside
            )

            splitButton.isEnabled = currentSurface.count > 1
            splitButton.alpha = splitButton.isEnabled ? 1 : 0.45

            updateMergeButtonAvailability()

            sheetController.view.addSubview(surfaceLabel)
            sheetController.view.addSubview(splitPanelContainer)
            sheetController.view.addSubview(actionMenuContainer)
            NSLayoutConstraint.activate([
                surfaceLabel.topAnchor.constraint(equalTo: sheetController.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                surfaceLabel.centerXAnchor.constraint(equalTo: sheetController.view.centerXAnchor),
                surfaceLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sheetController.view.leadingAnchor, constant: 16),
                surfaceLabel.trailingAnchor.constraint(lessThanOrEqualTo: sheetController.view.trailingAnchor, constant: -16),

                splitPanelContainer.topAnchor.constraint(equalTo: surfaceLabel.bottomAnchor, constant: 16),
                splitPanelContainer.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                splitPanelContainer.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),

                actionMenuContainer.leadingAnchor.constraint(equalTo: sheetController.view.leadingAnchor, constant: 16),
                actionMenuContainer.trailingAnchor.constraint(equalTo: sheetController.view.trailingAnchor, constant: -16),
                actionMenuContainer.bottomAnchor.constraint(equalTo: sheetController.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                actionMenuContainer.heightAnchor.constraint(equalToConstant: 46),

                splitPanelContainer.bottomAnchor.constraint(lessThanOrEqualTo: actionMenuContainer.topAnchor, constant: -12),
            ])

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
            case .left:
                onSheetSelectNext?()
            case .right:
                onSheetSelectPrevious?()
            default:
                break
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
