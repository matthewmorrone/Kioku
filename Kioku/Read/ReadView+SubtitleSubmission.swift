import SwiftUI
import UniformTypeIdentifiers

// Unified subtitle popup — handles audio file selection, alignment progress, and result display.
extension ReadView {
    // Displays a centered popup over a dimmed background for the full subtitle alignment flow.
    var subtitlePopupOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    if isGeneratingLyricAlignment == false {
                        dismissSubtitlePopup()
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                if alignmentResultSRT.isEmpty == false && isGeneratingLyricAlignment == false {
                    alignmentResultContent
                } else if isGeneratingLyricAlignment {
                    alignmentProgressContent
                } else {
                    audioSelectionContent
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // Clears popup state and dismisses.
    private func dismissSubtitlePopup() {
        isShowingSubtitlePopup = false
        alignmentResultSRT = ""
        clearPendingSubtitleFileSelection()
    }

    // Pre-alignment: pick audio and optionally an existing subtitle file.
    private var audioSelectionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Subtitles")
                .font(.headline)

            // Audio file picker row.
            filePickerRow(
                hasFile: pendingSubtitleAudioURL != nil,
                icon: "waveform",
                title: "Audio File",
                filename: pendingSubtitleAudioFilename.isEmpty ? "Choose..." : pendingSubtitleAudioFilename
            ) {
                subtitlePickerTarget = .audio
                isShowingSubtitlePicker = true
            }

            // Subtitle file picker row (optional — skips alignment if provided).
            filePickerRow(
                hasFile: pendingSubtitleFileURL != nil,
                icon: "captions.bubble",
                title: "Subtitle File",
                filename: pendingSubtitleFilename.isEmpty ? "Optional (.srt)" : pendingSubtitleFilename
            ) {
                subtitlePickerTarget = .subtitleFile
                isShowingSubtitlePicker = true
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismissSubtitlePopup()
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await submitPendingSubtitleSelection()
                    }
                } label: {
                    Text("Submit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingSubtitleAudioURL == nil)
            }
        }
    }

    // Builds a tappable row showing selection state, icon, title, and chosen filename.
    private func filePickerRow(
        hasFile: Bool,
        icon: String,
        title: String,
        filename: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: hasFile ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasFile ? Color.green : Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill((hasFile ? Color.green : Color.accentColor).opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(filename)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // During alignment: shows progress, streams partial SRT, and offers a cancel button.
    private var alignmentProgressContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(lyricAlignmentProgressMessage.isEmpty ? "Generating subtitles..." : lyricAlignmentProgressMessage)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .animation(.easeInOut(duration: 0.15), value: lyricAlignmentProgressMessage)
            }

            if alignmentResultSRT.isEmpty == false {
                ScrollView {
                    Text(alignmentResultSRT)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }

            Button("Cancel") {
                cancelAlignment()
            }
            .buttonStyle(.bordered)
            .disabled(isCancellingAlignment)
        }
    }

    // Post-alignment: shows the SRT output with mismatched lines highlighted, plus timing and normalization tools.
    private var alignmentResultContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Alignment Complete", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                Button {
                    dismissSubtitlePopup()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(highlightedAlignmentResult)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 260)

            Button("Done") {
                dismissSubtitlePopup()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }


    // Builds an AttributedString from the SRT result, coloring mismatched cue text lines orange.
    private var highlightedAlignmentResult: AttributedString {
        let mismatchedTexts = buildMismatchedCueTexts()
        var result = AttributedString()
        let lines = alignmentResultSRT.components(separatedBy: "\n")

        for (i, line) in lines.enumerated() {
            var attrLine = AttributedString(line)
            if mismatchedTexts.contains(line) {
                attrLine.foregroundColor = .orange
            }
            result.append(attrLine)
            if i < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    // Returns the set of cue text strings that don't match their corresponding note text.
    private func buildMismatchedCueTexts() -> Set<String> {
        var mismatched = Set<String>()
        for (index, cue) in audioAttachmentCues.enumerated() {
            guard SubtitleParser.isNonSpeechCue(cue.text) == false else { continue }
            guard index < audioAttachmentHighlightRanges.count,
                  let range = audioAttachmentHighlightRanges[index],
                  let swiftRange = Range(range, in: text) else { continue }
            let noteLineText = String(text[swiftRange])
            if noteLineText != cue.text {
                mismatched.insert(cue.text)
            }
        }
        return mismatched
    }
}
