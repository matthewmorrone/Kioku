import SwiftUI
import UniformTypeIdentifiers

// Subtitle popup — picks the audio (and optional sidecar) an alignment runs against. It closes
// the moment Submit starts a run: progress, cancel and failure all report from the lyric view's
// own chip (LyricsView+ReAlignBar), which is the single display for an alignment in flight.
extension ReadView {
    // Displays a centered popup over a dimmed background for picking alignment input files.
    var subtitlePopupOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissSubtitlePopup()
                }

            VStack(alignment: .leading, spacing: 14) {
                audioSelectionContent
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // Clears popup state and dismisses.
    private func dismissSubtitlePopup() {
        subtitleImport.isShowingSubtitlePopup = false
        clearPendingSubtitleFileSelection()
    }

    // Pre-alignment: pick audio and optionally an existing subtitle file.
    private var audioSelectionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Subtitles")
                .font(.headline)

            // Audio file picker row.
            filePickerRow(
                hasFile: subtitleImport.pendingSubtitleAudioURL != nil,
                icon: "waveform",
                title: "Audio File",
                filename: subtitleImport.pendingSubtitleAudioFilename.isEmpty ? "Choose..." : subtitleImport.pendingSubtitleAudioFilename
            ) {
                subtitleImport.subtitlePickerTarget = .audio
                subtitleImport.isShowingSubtitlePicker = true
            }

            // Subtitle file picker row (optional — skips alignment if provided).
            filePickerRow(
                hasFile: subtitleImport.pendingSubtitleFileURL != nil,
                icon: "captions.bubble",
                title: "Subtitle File",
                filename: subtitleImport.pendingSubtitleFilename.isEmpty ? "Optional (.srt)" : subtitleImport.pendingSubtitleFilename
            ) {
                subtitleImport.subtitlePickerTarget = .subtitleFile
                subtitleImport.isShowingSubtitlePicker = true
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismissSubtitlePopup()
                }
                .buttonStyle(.bordered)

                Button {
                    // Hand straight off to the lyric view: it owns the progress chip the run
                    // reports through, and once cues land it is where they're read anyway.
                    subtitleImport.isShowingSubtitlePopup = false
                    audioPlayback.isShowingLyricsView = true
                    Task {
                        await submitPendingSubtitleSelection()
                    }
                } label: {
                    Text("Submit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(subtitleImport.pendingSubtitleAudioURL == nil)
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

}
