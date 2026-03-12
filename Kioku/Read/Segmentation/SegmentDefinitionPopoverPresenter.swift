import UIKit

// Presents a native UIKit popover anchored to tapped segment rects in the read-mode text view.
final class SegmentDefinitionPopoverPresenter: NSObject, UIPopoverPresentationControllerDelegate, UIAdaptivePresentationControllerDelegate {
    static let shared = SegmentDefinitionPopoverPresenter()

    private weak var presentedController: UIViewController?
    private weak var presentedSheetController: UIViewController?
    private var onDismiss: (() -> Void)?
    private var onSheetSelectPrevious: (() -> Void)?
    private var onSheetSelectNext: (() -> Void)?
    private var updatePresentedSheetSelection: ((
        String,
        String?,
        String?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        (() -> Void)?
    ) -> Void)?

    // Prevents external construction so a single presenter coordinates popover lifecycle.
    private override init() {
        super.init()
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
        onDismiss: (() -> Void)? = nil
    ) {
        if let updatePresentedSheetSelection {
            self.onDismiss = onDismiss
            updatePresentedSheetSelection(
                surface,
                leftNeighborSurface,
                rightNeighborSurface,
                onSelectPrevious,
                onSelectNext,
                onMergeLeft,
                onMergeRight,
                onSplitApply,
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

    // Dismisses the currently presented action sheet if one is active.
    private func dismissSheet(completion: (() -> Void)? = nil) {
        guard let presentedSheetController else {
            onSheetSelectPrevious = nil
            onSheetSelectNext = nil
            updatePresentedSheetSelection = nil
            completion?()
            return
        }

        presentedSheetController.dismiss(animated: true) {
            completion?()
        }
        self.presentedSheetController = nil
        onSheetSelectPrevious = nil
        onSheetSelectNext = nil
        updatePresentedSheetSelection = nil
    }

    // Clears tracked presentation references when users dismiss controllers interactively.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentedController === presentationController.presentedViewController {
            presentedController = nil
            fireOnDismissIfNeeded()
        }

        if presentedSheetController === presentationController.presentedViewController {
            presentedSheetController = nil
            updatePresentedSheetSelection = nil
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

    // Presents a bottom sheet that starts at a fitted small detent and can expand to medium.
    private func presentSurfaceSheet(
        surface: String,
        leftNeighborSurface: String?,
        rightNeighborSurface: String?,
        onSelectPrevious: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onSelectNext: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onMergeLeft: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onMergeRight: (() -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onSplitApply: ((Int) -> (surface: String, leftNeighborSurface: String?, rightNeighborSurface: String? )?)?,
        onDismiss: (() -> Void)?
    ) {
        dismissPopover(notifyDismissal: false) { [weak self] in
            guard let self, let presenter = self.topPresentingController() else {
                return
            }

            self.onDismiss = onDismiss
            self.onSheetSelectPrevious = nil
            self.onSheetSelectNext = nil

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
                currentSheetPreferredHeight = self.preferredSurfaceSheetHeight(
                    for: currentSurface,
                    isSplitEditorVisible: isSplitEditorVisible
                )

                guard let sheetPresentationController = sheetController.sheetPresentationController else {
                    return
                }

                if #available(iOS 16.0, *) {
                    let updates = {
                        sheetPresentationController.invalidateDetents()
                    }

                    if animated {
                        sheetPresentationController.animateChanges(updates)
                    } else {
                        updates()
                    }
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
                updateSheetPreferredHeight(animated: true)
            }

            self.onSheetSelectPrevious = {
                guard isSplitEditorVisible == false, let outcome = currentOnSelectPrevious?() else {
                    return
                }

                updateCurrentSurface(outcome)
                updateSheetPreferredHeight(animated: true)
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
                updatedOnDismiss in
                currentOnSelectPrevious = updatedOnSelectPrevious
                currentOnSelectNext = updatedOnSelectNext
                currentOnMergeLeft = updatedOnMergeLeft
                currentOnMergeRight = updatedOnMergeRight
                currentOnSplitApply = updatedOnSplitApply
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

            presenter.present(sheetController, animated: true)
            self.presentedSheetController = sheetController
        }
    }

    // Delivers and clears one-shot dismissal callback used by the read view to clear selection state.
    private func fireOnDismissIfNeeded() {
        guard let onDismiss else {
            return
        }

        self.onDismiss = nil
        onDismiss()
    }

    // Routes horizontal sheet swipe gestures to the current selection-navigation callbacks.
    @objc private func handleSheetSwipe(_ gestureRecognizer: UISwipeGestureRecognizer) {
        switch gestureRecognizer.direction {
        case .left:
            onSheetSelectNext?()
        case .right:
            onSheetSelectPrevious?()
        default:
            break
        }
    }

    // Generates initial left and right segment groups for split mode from the tapped surface text.
    private func initialSplitSegments(for surface: String) -> (left: [String], right: [String]) {
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
    private func segmentizeSurface(_ surface: String) -> [String] {
        let whitespaceSegments = surface
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        if whitespaceSegments.isEmpty == false {
            return whitespaceSegments
        }

        return surface.map { String($0) }
    }

    // Rebuilds one segment row with tappable chip buttons that transfer segments across split inputs.
    private func rebuildSegmentRow(
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

    // Computes fitted sheet height for current visible content state.
    private func preferredSurfaceSheetHeight(for surface: String, isSplitEditorVisible: Bool) -> CGFloat {
        let label = UILabel()
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.numberOfLines = 0
        label.text = surface

        let availableWidth = max(200, activeScreenBounds().width - 32)
        let measured = label.sizeThatFits(
            CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        )

        // Includes grabber/safe-area/top+bottom paddings and action row so title never clips.
        let baseChrome: CGFloat = 176
        let splitEditorExtra: CGFloat = isSplitEditorVisible ? 128 : 0
        let minimumCollapsedHeight: CGFloat = 260
        return min(max(minimumCollapsedHeight, ceil(measured.height) + baseChrome + splitEditorExtra), 440)
    }

    // Resolves the active screen bounds without relying on deprecated global UIScreen access.
    private func activeScreenBounds() -> CGRect {
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return CGRect(x: 0, y: 0, width: 390, height: 844)
        }

        return windowScene.screen.bounds
    }

    // Resolves the top-most view controller so popovers present from the active screen context.
    private func topPresentingController() -> UIViewController? {
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
}
