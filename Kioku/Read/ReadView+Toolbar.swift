import SwiftUI

// Toolbar buttons and display options popover for ReadView.
extension ReadView {
    // Renders action buttons for segmentation and display controls.
    var toolbarButtons: some View {
        HStack {
            // ♪ button — only when audio and subtitles are both loaded.
            if audioController.duration > 0 && audioAttachmentCues.isEmpty == false {
                Button {
                    isShowingLyricsView.toggle()
                } label: {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isShowingLyricsView ? Color(.systemOrange) : Color.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Lyrics")
            }
            Spacer()
            llmCorrectionButton
            resetButton
            segmentListButton
            furiganaButton
            editModeButton
        }
    }

    // Triggers an LLM correction request for the current note's segmentation and readings.
    // While changes are pending, acts as a confirm button (sparkles + checkmark overlay).
    // Only enabled when a provider key is configured in Settings and the note is in read mode.
    var llmCorrectionButton: some View {
        Button {
            if isRequestingLLMCorrection {
                cancelLLMCorrection()
            } else if hasPendingLLMChanges {
                confirmLLMChanges()
            } else if segments != nil {
                isShowingLLMRerunConfirm = true
            } else {
                requestLLMCorrection()
            }
        } label: {
            Group {
                if isRequestingLLMCorrection {
                    ZStack {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 7, weight: .semibold))
                    }
                } else if hasPendingLLMChanges {
                    // Sparkles with a checkmark badge signals "confirm these AI changes".
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .offset(x: 4, y: 4)
                    }
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(hasPendingLLMChanges ? Color.green : Color.accentColor)
            .frame(width: 36, height: 36)
            .background(Circle().fill(hasPendingLLMChanges ? Color.green.opacity(0.15) : Color(.tertiarySystemFill)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 1.0)
        .accessibilityLabel(hasPendingLLMChanges ? "Confirm AI Changes" : (isRequestingLLMCorrection ? "Cancel AI Correction" : "Request AI Correction"))
    }

    // Resets custom segment segmentation back to computed segmentation.
    // While LLM changes are pending, shows a red X badge to signal "reject all AI changes".
    var resetButton: some View {
        Button {
            resetSegmentationToComputed()
        } label: {
            Group {
                if hasPendingLLMChanges {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .offset(x: 4, y: 4)
                    }
                    .foregroundStyle(Color.red)
                } else {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(segments == nil ? Color.secondary.opacity(0.5) : Color.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .background(Circle().fill(hasPendingLLMChanges ? Color.red.opacity(0.15) : Color(.tertiarySystemFill)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled((segments == nil && hasPendingLLMChanges == false) || isEditMode)
        .opacity((segments == nil && hasPendingLLMChanges == false) || isEditMode ? 0.5 : 0.7)
        .accessibilityLabel(hasPendingLLMChanges ? "Reject AI Changes" : "Reset Segmentation")
    }

    // Opens the segment list screen for split/merge actions synced to the paste area.
    var segmentListButton: some View {
        Button {
            isShowingSegmentList = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEditMode ? Color.secondary.opacity(0.5) : Color.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 0.7)
        .accessibilityLabel("Show Segment List")
    }

    // Toggles whether furigana annotations render in the main paste area.
    // Long press opens display options popover.
    var furiganaButton: some View {
        furiganaButtonLabel
        .contentShape(Circle())
        .onTapGesture {
            guard isEditMode == false else { return }
            isFuriganaVisible.toggle()
        }
        .onLongPressGesture(minimumDuration: 0.35) {
            guard isEditMode == false else { return }
            isShowingDisplayOptions = true
        }
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 0.8)
        .accessibilityLabel(isFuriganaVisible ? "Hide Furigana" : "Show Furigana")
        .accessibilityHint("Long press for display options")
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isShowingDisplayOptions, arrowEdge: .bottom) {
            displayOptionsPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    // Renders the title-row button that creates and selects a fresh note for immediate editing.
    var newNoteButton: some View {
        Button {
            flushPendingNotePersistenceIfNeeded()
            notesStore.addNote()
            guard let createdNote = notesStore.notes.first else { return }
            shouldActivateEditModeOnLoad = true
            selectedNote = createdNote
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Note")
    }

    // Renders the tappable furigana icon that also exposes display options on long press.
    var furiganaButtonLabel: some View {
        Image(isFuriganaVisible ? "furigana.on" : "furigana.off")
            .renderingMode(.template)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isFuriganaVisible ? Color.accentColor : Color.secondary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color(.tertiarySystemFill)))
    }

    // Presents display option toggles with persistent enabled-state styling.
    var displayOptionsPopover: some View {
        VStack(spacing: 10) {
            displayOptionRow(
                title: "Apply Changes Globally",
                systemImage: "arrow.triangle.branch",
                isEnabled: shouldApplyChangesGlobally
            ) {
                shouldApplyChangesGlobally.toggle()
            }

            displayOptionRow(
                title: "Highlight Unknown",
                systemImage: isHighlightUnknownEnabled ? "questionmark.circle.fill" : "questionmark.circle",
                isEnabled: isHighlightUnknownEnabled
            ) {
                isHighlightUnknownEnabled.toggle()
            }

            displayOptionRow(
                title: "Segment Colors",
                systemImage: isColorAlternationEnabled ? "paintpalette.fill" : "paintpalette",
                isEnabled: isColorAlternationEnabled
            ) {
                isColorAlternationEnabled.toggle()
            }

            displayOptionRow(
                title: "Line Wrapping",
                systemImage: isLineWrappingEnabled ? "text.alignleft" : "arrow.right.to.line.compact",
                isEnabled: isLineWrappingEnabled
            ) {
                isLineWrappingEnabled.toggle()
            }
        }
        .padding(12)
        .frame(width: 270)
        .background(Color(.systemBackground))
    }

    // Renders one display-option row with a highlighted background while its toggle is enabled.
    func displayOptionRow(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isEnabled ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)

                Spacer(minLength: 0)

                if isEnabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isEnabled ? Color.accentColor.opacity(0.16) : Color(.tertiarySystemFill))
            )
        }
        .buttonStyle(.plain)
    }

    // Uses one icon button whose visual treatment reflects active edit state.
    var editModeButton: some View {
        Button {
            isEditMode.toggle()
        } label: {
            Image(systemName: "character.cursor.ibeam.ja")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEditMode ? Color.white : Color.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(isEditMode ? Color.accentColor : Color(.tertiarySystemFill)))
        }
        .buttonStyle(PlainButtonStyle())
        .opacity(isEditMode ? 1 : 0.7)
        .accessibilityLabel(isEditMode ? "Disable Edit Mode" : "Enable Edit Mode")
    }
}
