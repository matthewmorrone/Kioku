import SwiftUI

// Single source of truth for the Read tab's toggle appearance, modeled on the
// furigana button: a constant neutral background, with the foreground switching
// between accent (on) and secondary (off). Every toggle on the Read tab — the
// icon buttons in the toolbar / title rows, the display-options popover rows,
// and the pill filters in the segment list and lyrics views — routes its colors
// through here so the whole tab speaks one visual language. The background never
// changes with state; only the foreground signals on/off.
enum ReadToggleAppearance {
    static let background = Color(.tertiarySystemFill)

    // Accent when the toggle is on, secondary when off — the only thing that
    // changes with state, since the background stays constant.
    static func foreground(isOn: Bool) -> Color {
        isOn ? Color.accentColor : Color.secondary
    }
}

// Toolbar buttons and display options popover for ReadView.
extension ReadView {
    // Renders action buttons for segmentation and display controls. The lyrics (♪) and
    // extract-words (list.bullet) buttons that used to live here moved up to the title
    // row, so this row now hosts only the per-note correction / reset / furigana / edit
    // controls.
    var toolbarButtons: some View {
        HStack {
            Spacer()
            if isLLMConfigured {
                llmCorrectionButton
            }
            resetButton
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
            } else if hasAppliedLLMCorrectionForCurrentNote {
                // Only warn about replacing corrections once this note has actually had one
                // applied — a fresh note runs straight away without the confirm dialog.
                isShowingLLMRerunConfirm = true
            } else {
                requestLLMCorrection()
            }
        } label: {
            Group {
                if isRequestingLLMCorrection {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
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
            .background(Circle().fill(ReadToggleAppearance.background))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isEditMode)
        .opacity(isEditMode ? 0.5 : 1.0)
        .accessibilityLabel(hasPendingLLMChanges ? "Confirm AI Changes" : (isRequestingLLMCorrection ? "Cancel AI Correction" : "Request AI Correction"))
    }

    // Resets custom segment segmentation back to computed segmentation.
    // While LLM changes are pending, shows a red X badge to signal "reject all AI changes".
    var resetButton: some View {
        // Enabled only when the user has actually changed this note's segmentation or readings
        // (or there are pending AI changes to reject) and the note isn't in edit mode. Uses the
        // explicit edit marker rather than `segments != nil`, which is true even for imported /
        // precomputed notes that were never touched. Per the toggle standard, an enabled reset
        // reads as "on" (accent) and a disabled one as "off" (secondary); the red reject badge
        // overrides while AI changes are pending.
        let isEnabled = (hasManualSegmentationEdits || hasPendingLLMChanges) && isEditMode == false
        return Button {
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
                        .foregroundStyle(ReadToggleAppearance.foreground(isOn: isEnabled))
                }
            }
            .frame(width: 36, height: 36)
            .background(Circle().fill(ReadToggleAppearance.background))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.5)
        .accessibilityLabel(hasPendingLLMChanges ? "Reject AI Changes" : "Reset Segmentation")
    }

    // Title-row buttons. New-note + OCR migrated to the Notes tab; this row hosts the
    // per-note quick actions: open the lyrics view (♪), open the segment list / extract-words
    // (list.bullet), and open the LLM breakdown sheet (sparkles in a circle). All three are
    // visual peers — same capsule background, same accent treatment — so the row reads as
    // "actions for the currently-open note."
    var titleLyricsButton: some View {
        titleActionLabel(systemImage: "music.note", foreground: ReadToggleAppearance.foreground(isOn: isShowingLyricsView))
            .contentShape(Capsule())
            .onTapGesture {
                // Nothing attached yet → the lyric view would be empty, so jump straight to the
                // media picker (mp3 / srt / textgrid) instead of toggling a blank overlay. Once an
                // attachment exists, the tap reverts to its normal show/hide-lyrics behavior.
                if activeAudioAttachmentID == nil {
                    isShowingLyricMediaPicker = true
                } else {
                    isShowingLyricsView.toggle()
                }
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                // Long press opens the subtitle editor sheet — the only place to access
                // the alignment menu (Reconcile from Note / Re-time / Validate / etc.).
                // Mirrors the furigana button's tap-toggles-state, long-press-opens-tools
                // affordance. presentSubtitleEditorIfPossible() lazy-loads the audio
                // attachment first when needed, so it's safe to call without checking.
                presentSubtitleEditorIfPossible()
            }
            .accessibilityLabel(isShowingLyricsView ? "Hide Lyrics" : "Show Lyrics")
            .accessibilityHint("Long press to edit subtitles")
            .accessibilityAddTraits(.isButton)
    }

    var titleExtractWordsButton: some View {
        Button {
            isShowingSegmentList = true
        } label: {
            titleActionLabel(systemImage: "list.bullet", foreground: .accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Extract Words")
    }

    var titleBreakdownButton: some View {
        Button {
            isShowingBreakdownSheet = true
        } label: {
            titleActionLabel(systemImage: "sparkles.rectangle.stack", foreground: .accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Breakdown")
    }

    // Shared visual treatment for the three title-row action buttons. Sized to match the
    // bottom toolbar's furigana / reset / edit buttons (36×36 with a 16pt icon) so the
    // two rows read as visual peers — same hit area, same inter-button gap when each row
    // is laid out with default `HStack` spacing. Previously the visible pill was 30×30
    // wrapped in a 44×44 hit frame, which made HStack measure ~14pt of invisible padding
    // per button and pushed the top row's perceived spacing well past the bottom row's.
    private func titleActionLabel(systemImage: String, foreground: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 36, height: 36)
            .background(Capsule().fill(ReadToggleAppearance.background))
            .contentShape(Rectangle())
    }

    // Presents display option toggles with persistent enabled-state styling.
    var displayOptionsPopover: some View {
        VStack(spacing: 10) {
            displayOptionRow(
                title: "Furigana",
                image: Image(isFuriganaVisible ? "furigana.on" : "furigana.off")
                    .renderingMode(.template),
                isEnabled: isFuriganaVisible
            ) {
                isFuriganaVisible.toggle()
            }

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

            // The indicator mirrors the stored flag directly: `isLineWrappingEnabled == true`
            // maps to `.byWordWrapping` in every render site, so a checkmark/highlight means
            // "lines are wrapping." No inversion — display and behavior track the same flag.
            displayOptionRow(
                title: "Line Wrapping",
                systemImage: isLineWrappingEnabled ? "text.alignleft" : "arrow.right.to.line.compact",
                isEnabled: isLineWrappingEnabled
            ) {
                isLineWrappingEnabled.toggle()
            }

            displayOptionRow(
                title: "Ruby Spacing",
                systemImage: isRubySpacingEnabled ? "arrow.left.and.right.text.vertical" : "arrow.left.and.right",
                isEnabled: isRubySpacingEnabled
            ) {
                isRubySpacingEnabled.toggle()
            }

            displayOptionRow(
                title: "Favorited Glow",
                systemImage: isFavoritedGlowEnabled ? "star.fill" : "star",
                isEnabled: isFavoritedGlowEnabled
            ) {
                isFavoritedGlowEnabled.toggle()
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
        displayOptionRow(
            title: title,
            image: Image(systemName: systemImage),
            isEnabled: isEnabled,
            action: action
        )
    }

    // Image-based overload of displayOptionRow for rows whose icon is a custom Image
    // asset rather than an SF Symbol — e.g. the furigana glyph, which is a project
    // asset, not a system symbol. Shares all other styling with the systemImage variant
    // so the popover keeps a single visual language.
    func displayOptionRow(
        title: String,
        image: Image,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                image
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ReadToggleAppearance.foreground(isOn: isEnabled))
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ReadToggleAppearance.foreground(isOn: isEnabled))
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
                    .fill(ReadToggleAppearance.background)
            )
        }
        .buttonStyle(.plain)
    }

    // One icon button whose visual treatment reflects active edit state. Tap toggles
    // edit mode; long press opens the display-options popover (which now hosts furigana
    // alongside the other view-mode toggles). Locked while an LLM correction is in flight:
    // entering edit mode mid-call would let the user mutate `text` out from under the
    // apply pipeline, which validates the response against the text that was originally
    // submitted. Cheaper than threading a background task across view transitions — the
    // call only survives a couple of minutes, and the user can still navigate elsewhere;
    // they just can't edit until the correction lands. The popover stays available even
    // while the button is disabled would feel wrong, so the long-press is gated on the
    // same condition as the tap.
    var editModeButton: some View {
        editModeButtonLabel
            .contentShape(Circle())
            .onTapGesture {
                guard isRequestingLLMCorrection == false else { return }
                isEditMode.toggle()
            }
            .onLongPressGesture(minimumDuration: 0.35) {
                guard isRequestingLLMCorrection == false else { return }
                isShowingDisplayOptions = true
            }
            .disabled(isRequestingLLMCorrection)
            .opacity(isRequestingLLMCorrection ? 0.4 : (isEditMode ? 1 : 0.7))
            .accessibilityLabel(isEditMode ? "Disable Edit Mode" : "Enable Edit Mode")
            .accessibilityHint(isRequestingLLMCorrection ? "Disabled while AI correction runs" : "Long press for display options")
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $isShowingDisplayOptions, arrowEdge: .bottom) {
                displayOptionsPopover
                    .presentationCompactAdaptation(.popover)
            }
    }

    // Renders the edit-mode glyph so the gesture-driven editModeButton has a label view
    // to attach taps and long-presses to without nesting them inside a Button.
    private var editModeButtonLabel: some View {
        Image(systemName: "character.cursor.ibeam.ja")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(ReadToggleAppearance.foreground(isOn: isEditMode))
            .frame(width: 36, height: 36)
            .background(Circle().fill(ReadToggleAppearance.background))
    }
}
