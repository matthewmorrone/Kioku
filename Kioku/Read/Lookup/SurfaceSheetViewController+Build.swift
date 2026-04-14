import UIKit
import AVFoundation

// View construction and action wiring for SurfaceSheetViewController.
// Split from the main file to keep each file under the 800-line preferred limit.
extension SurfaceSheetViewController {

    // Constructs the furigana header row, reading navigation arrows, and lemma label.
    func buildHeader() {
        guard let sheet else { return }
        let components = sheet.makeSheetHeaderView(surface: currentSurface, initialReading: sheet.currentSheetUniqueReadings.first)
        headerStack = components.stack
        headerRow = components.row
        lemmaLabel = components.lemmaLabel

        headerContainer = UIView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false

        prevReadingButton = UIButton(type: .system)
        prevReadingButton.translatesAutoresizingMaskIntoConstraints = false
        prevReadingButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        prevReadingButton.tintColor = .tertiaryLabel
        prevReadingButton.accessibilityLabel = "Previous Reading"

        nextReadingButton = UIButton(type: .system)
        nextReadingButton.translatesAutoresizingMaskIntoConstraints = false
        nextReadingButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        nextReadingButton.tintColor = .tertiaryLabel
        nextReadingButton.accessibilityLabel = "Next Reading"

        headerContainer.addSubview(headerStack)
        headerContainer.addSubview(prevReadingButton)
        headerContainer.addSubview(nextReadingButton)

        let readingButtonSize: CGFloat = 36
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            headerStack.centerXAnchor.constraint(equalTo: headerContainer.centerXAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            headerStack.leadingAnchor.constraint(greaterThanOrEqualTo: prevReadingButton.trailingAnchor, constant: 8),
            headerStack.trailingAnchor.constraint(lessThanOrEqualTo: nextReadingButton.leadingAnchor, constant: -8),

            prevReadingButton.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            prevReadingButton.widthAnchor.constraint(equalToConstant: readingButtonSize),
            prevReadingButton.heightAnchor.constraint(equalToConstant: readingButtonSize),
            prevReadingButton.centerYAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -18),

            nextReadingButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            nextReadingButton.widthAnchor.constraint(equalToConstant: readingButtonSize),
            nextReadingButton.heightAnchor.constraint(equalToConstant: readingButtonSize),
            nextReadingButton.centerYAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: -18),
        ])

        // Tapping the header row opens a custom reading alert.
        let headerTapHandler = ClosureTarget { [weak self] in
            self?.presentCustomReadingAlert()
        }
        let headerTapRecognizer = UITapGestureRecognizer(target: headerTapHandler, action: #selector(ClosureTarget.invoke))
        headerTapRecognizer.cancelsTouchesInView = false
        headerStack.isUserInteractionEnabled = true
        headerStack.addGestureRecognizer(headerTapRecognizer)
        objc_setAssociatedObject(headerStack as Any, &SegmentLookupSheet.tapHandlerKey, headerTapHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // Constructs the split boundary editor panel (hidden by default).
    func buildSplitPanel() {
        splitPanelContainer = UIStackView()
        splitPanelContainer.translatesAutoresizingMaskIntoConstraints = false
        splitPanelContainer.axis = .vertical
        splitPanelContainer.spacing = 14
        splitPanelContainer.isHidden = true
        // isHidden doesn't collapse Auto Layout frames — explicit zero height prevents the
        // hidden split panel from pushing content out of the sheet's visible bounds.
        splitPanelCollapsedConstraint = splitPanelContainer.heightAnchor.constraint(equalToConstant: 0)
        splitPanelCollapsedConstraint.isActive = true

        let splitInputsRow = UIStackView()
        splitInputsRow.axis = .horizontal
        splitInputsRow.spacing = 12
        splitInputsRow.alignment = .center
        splitInputsRow.distribution = .fill

        leftInput = UITextField()
        leftInput.translatesAutoresizingMaskIntoConstraints = false
        leftInput.borderStyle = .roundedRect
        leftInput.font = .systemFont(ofSize: 22, weight: .medium)
        leftInput.textColor = .label
        leftInput.placeholder = "Left"
        leftInput.isUserInteractionEnabled = false
        leftInput.textAlignment = .right

        rightInput = UITextField()
        rightInput.translatesAutoresizingMaskIntoConstraints = false
        rightInput.borderStyle = .roundedRect
        rightInput.font = .systemFont(ofSize: 22, weight: .medium)
        rightInput.textColor = .label
        rightInput.placeholder = "Right"
        rightInput.isUserInteractionEnabled = false
        rightInput.textAlignment = .left

        let leftInputContainer = UIView()
        leftInputContainer.translatesAutoresizingMaskIntoConstraints = false
        leftInputTapButton = UIButton(type: .custom)
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
        rightInputTapButton = UIButton(type: .custom)
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

        cancelSplitButton = UIButton(type: .system)
        cancelSplitButton.translatesAutoresizingMaskIntoConstraints = false
        cancelSplitButton.setTitle("Cancel", for: .normal)
        cancelSplitButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        cancelSplitButton.tintColor = .systemBlue
        cancelSplitButton.backgroundColor = .tertiarySystemFill
        cancelSplitButton.layer.cornerRadius = 22

        applySplitButton = UIButton(type: .system)
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
    }

    // Constructs the word-actions row (speak, save, open) and segmentation-actions row (merge-left, split, merge-right).
    func buildActionMenu() {
        actionMenuContainer = UIView()
        actionMenuContainer.translatesAutoresizingMaskIntoConstraints = false
        actionMenuContainer.backgroundColor = .secondarySystemBackground
        actionMenuContainer.layer.cornerRadius = 10

        // Top row: speak, save, open-detail.
        wordActionsStack = UIStackView()
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

        let isSavedInitially = sheet?.sheetIsSavedProvider?() ?? false
        saveButton = UIButton(type: .system)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setImage(UIImage(systemName: isSavedInitially ? "star.fill" : "star"), for: .normal)
        saveButton.tintColor = isSavedInitially ? .systemYellow : .secondaryLabel
        saveButton.backgroundColor = .tertiarySystemFill
        saveButton.layer.cornerRadius = 8
        saveButton.accessibilityLabel = isSavedInitially ? "Unsave" : "Save"

        openDetailButton = UIButton(type: .system)
        openDetailButton.translatesAutoresizingMaskIntoConstraints = false
        openDetailButton.setImage(UIImage(systemName: "text.magnifyingglass"), for: .normal)
        openDetailButton.tintColor = .secondaryLabel
        openDetailButton.backgroundColor = .tertiarySystemFill
        openDetailButton.layer.cornerRadius = 8
        openDetailButton.accessibilityLabel = "Look Up in Words"

        wordActionsStack.addArrangedSubview(speakButton)
        wordActionsStack.addArrangedSubview(saveButton)
        wordActionsStack.addArrangedSubview(openDetailButton)

        // Bottom row: merge-left, split, merge-right.
        let actionMenuStack = UIStackView()
        actionMenuStack.translatesAutoresizingMaskIntoConstraints = false
        actionMenuStack.axis = .horizontal
        actionMenuStack.spacing = 8
        actionMenuStack.alignment = .fill
        actionMenuStack.distribution = .fillEqually

        mergeLeftButton = UIButton(type: .system)
        mergeLeftButton.translatesAutoresizingMaskIntoConstraints = false
        mergeLeftButton.setImage(UIImage(systemName: "arrow.left.to.line.compact"), for: .normal)
        mergeLeftButton.tintColor = .secondaryLabel
        mergeLeftButton.backgroundColor = .tertiarySystemFill
        mergeLeftButton.layer.cornerRadius = 8

        splitButton = UIButton(type: .system)
        splitButton.translatesAutoresizingMaskIntoConstraints = false
        splitButton.setImage(UIImage(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right"), for: .normal)
        splitButton.tintColor = .secondaryLabel
        splitButton.backgroundColor = .tertiarySystemFill
        splitButton.layer.cornerRadius = 8

        mergeRightButton = UIButton(type: .system)
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

        // Speak button retains the synthesizer via associated object so it lives long enough to finish.
        speakButton.addAction(UIAction { [weak speakButton, weak self] _ in
            guard let self else { return }
            let synthesizer = AVSpeechSynthesizer()
            objc_setAssociatedObject(speakButton as Any, &SegmentLookupSheet.speechSynthesizerKey, synthesizer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let utterance = AVSpeechUtterance(string: currentSurface)
            utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
            synthesizer.speak(utterance)
        }, for: .touchUpInside)
    }

    // Builds the vertical content stack between the header and the action menu,
    // wrapped in a rounded container matching the action menu styling.
    func buildMiddleContent() {
        middleContentContainer = UIView()
        middleContentContainer.translatesAutoresizingMaskIntoConstraints = false
        middleContentContainer.backgroundColor = .secondarySystemBackground
        middleContentContainer.layer.cornerRadius = 10

        middleContentStack = UIStackView()
        middleContentStack.translatesAutoresizingMaskIntoConstraints = false
        middleContentStack.axis = .vertical
        middleContentStack.spacing = 12
        middleContentStack.alignment = .fill

        middleContentContainer.addSubview(middleContentStack)
        NSLayoutConstraint.activate([
            middleContentStack.topAnchor.constraint(equalTo: middleContentContainer.topAnchor, constant: 6),
            middleContentStack.leadingAnchor.constraint(equalTo: middleContentContainer.leadingAnchor, constant: 6),
            middleContentStack.trailingAnchor.constraint(equalTo: middleContentContainer.trailingAnchor, constant: -6),
            middleContentStack.bottomAnchor.constraint(equalTo: middleContentContainer.bottomAnchor, constant: -6),
        ])
    }

    // Adds all major subviews to the controller's root view and activates layout constraints.
    func layoutRootSubviews() {
        view.addSubview(headerContainer)
        view.addSubview(splitPanelContainer)
        view.addSubview(middleContentContainer)
        view.addSubview(actionMenuContainer)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            splitPanelContainer.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 8),
            splitPanelContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            splitPanelContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            middleContentContainer.topAnchor.constraint(equalTo: splitPanelContainer.bottomAnchor, constant: 16),
            middleContentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            middleContentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            middleContentContainer.bottomAnchor.constraint(lessThanOrEqualTo: actionMenuContainer.topAnchor, constant: -12),
            actionMenuContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            actionMenuContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            actionMenuContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    // Connects all button and gesture targets after the view hierarchy is established.
    func wireActions() {
        saveButton.addAction(UIAction { [weak self] _ in
            self?.sheet?.sheetSaveToggle?()
            self?.updateSaveButtonAppearance()
        }, for: .touchUpInside)

        openDetailButton.addAction(UIAction { [weak self] _ in
            let openWordDetail = self?.sheet?.sheetOpenWordDetail
            self?.sheet?.dismissPopover(notifyDismissal: false) {
                DispatchQueue.main.async { openWordDetail?() }
            }
        }, for: .touchUpInside)

        prevReadingButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let total = currentReadings.count
            guard total > 1 else { return }
            customReading = nil
            currentReadingIndex = (currentReadingIndex - 1 + total) % total
            syncFuriganaToCurrentIndex()
            applyCurrentReadingSelection()
            updateMiddleContent()
        }, for: .touchUpInside)

        nextReadingButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let total = currentReadings.count
            guard total > 1 else { return }
            customReading = nil
            currentReadingIndex = (currentReadingIndex + 1) % total
            syncFuriganaToCurrentIndex()
            applyCurrentReadingSelection()
            updateMiddleContent()
        }, for: .touchUpInside)

        mergeLeftButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if let callback = currentOnMergeLeft {
                // Callback provided — a nil return means the model rejected the merge (e.g. illegal boundary).
                // Do not fall back to string concatenation; the model's rejection stands.
                guard let mergeResult = callback() else { return }
                updateCurrentSurface(mergeResult)
            } else if let leftNeighbor = currentLeftNeighborSurface {
                // No callback — display-only context where merge is not backed by the model.
                currentSurface = leftNeighbor + currentSurface
                currentLeftNeighborSurface = nil
                syncFuriganaToCurrentIndex()
            } else {
                return
            }
            splitButton.isEnabled = currentSurface.count > 1
            splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
            updateMergeButtonAvailability()
            if isSplitEditorVisible { resetSplitInputs(using: currentSurface) }
            sheet?.refreshSheetSupplementalData()
            updateReadingFurigana()
            updateLemmaChain()
            updateMiddleContent()
            updateOpenDetailButtonAppearance()
            updateSheetPreferredHeight(animated: true)
        }, for: .touchUpInside)

        mergeRightButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if let callback = currentOnMergeRight {
                // Callback provided — a nil return means the model rejected the merge (e.g. illegal boundary).
                // Do not fall back to string concatenation; the model's rejection stands.
                guard let mergeResult = callback() else { return }
                updateCurrentSurface(mergeResult)
            } else if let rightNeighbor = currentRightNeighborSurface {
                // No callback — display-only context where merge is not backed by the model.
                currentSurface = currentSurface + rightNeighbor
                currentRightNeighborSurface = nil
                syncFuriganaToCurrentIndex()
            } else {
                return
            }
            splitButton.isEnabled = currentSurface.count > 1
            splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
            updateMergeButtonAvailability()
            if isSplitEditorVisible { resetSplitInputs(using: currentSurface) }
            sheet?.refreshSheetSupplementalData()
            updateReadingFurigana()
            updateLemmaChain()
            updateMiddleContent()
            updateOpenDetailButtonAppearance()
            updateSheetPreferredHeight(animated: true)
        }, for: .touchUpInside)

        splitButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let characters = Array(currentSurface)
            guard characters.count > 1 else { return }
            if characters.count == 2 {
                let offset = String(characters[0]).utf16.count
                if let splitResult = currentOnSplitApply?(offset) {
                    updateCurrentSurface(splitResult)
                    sheet?.refreshSheetSupplementalData()
                    updateReadingFurigana()
                    updateLemmaChain()
                    updateMiddleContent()
                    updateOpenDetailButtonAppearance()
                    updateSheetPreferredHeight(animated: true)
                }
                return
            }
            setSplitEditorVisible(true)
            resetSplitInputs(using: currentSurface)
            splitEntryLeftValue = leftSplitValue
            splitEntryRightValue = rightSplitValue
        }, for: .touchUpInside)

        leftInputTapButton.addAction(UIAction { [weak self] _ in
            guard let self, rightSplitValue.count > 1, let movedCharacter = rightSplitValue.first else { return }
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
        }, for: .touchUpInside)

        rightInputTapButton.addAction(UIAction { [weak self] _ in
            guard let self, leftSplitValue.count > 1, let movedCharacter = leftSplitValue.last else { return }
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
        }, for: .touchUpInside)

        cancelSplitButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            leftSplitValue = splitEntryLeftValue
            rightSplitValue = splitEntryRightValue
            leftInput.text = leftSplitValue
            rightInput.text = rightSplitValue
            setSplitEditorVisible(false)
        }, for: .touchUpInside)

        applySplitButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let splitOffset = leftSplitValue.utf16.count
            if let callback = currentOnSplitApply {
                // Callback provided — a nil return means the model rejected the split (e.g. invalid offset).
                // Do not fall back to string concatenation; the model's rejection stands.
                guard let splitResult = callback(splitOffset) else { return }
                updateCurrentSurface(splitResult)
            } else {
                // No callback — display-only context where split is not backed by the model.
                currentSurface = leftSplitValue + rightSplitValue
                syncFuriganaToCurrentIndex()
            }
            splitButton.isEnabled = currentSurface.count > 1
            splitButton.alpha = splitButton.isEnabled ? 1 : 0.45
            updateMergeButtonAvailability()
            setSplitEditorVisible(false)
            sheet?.refreshSheetSupplementalData()
            updateReadingFurigana()
            updateLemmaChain()
            updateMiddleContent()
            updateSheetPreferredHeight(animated: true)
        }, for: .touchUpInside)

        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSheetSwipe(_:)))
        swipeLeft.direction = .left
        view.addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSheetSwipe(_:)))
        swipeRight.direction = .right
        view.addGestureRecognizer(swipeRight)
    }
}
