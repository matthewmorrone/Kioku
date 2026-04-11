import SwiftUI
import UniformTypeIdentifiers

// Subtitle submission sheet UI — the bottom sheet for attaching audio + subtitle files to a note.
extension ReadView {
    var subtitleSubmissionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Subtitles")
                    .font(.headline)
                Spacer()
                Button {
                    isShowingSubtitleSubmissionSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 10) {
                subtitleSelectionButton(
                    title: "Audio File",
                    systemImage: "waveform",
                    value: pendingSubtitleAudioFilename.isEmpty ? "Choose..." : pendingSubtitleAudioFilename
                ) {
                    presentFileImporter(for: .subtitleAudio)
                }

                if pendingSubtitleAudioURL != nil {
                    Button("Remove Audio", role: .destructive) {
                        removePendingSubtitleAudioSelection()
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    isShowingSubtitleSubmissionSheet = false
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await submitPendingSubtitleSelection()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isGeneratingLyricAlignment {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Submit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingSubtitleAudioURL == nil || isGeneratingLyricAlignment)
            }
        }
        .padding(20)
        .interactiveDismissDisabled(isGeneratingLyricAlignment)
        .fileImporter(
            isPresented: isShowingSubtitleFileImporter,
            allowedContentTypes: activeFileImportTarget?.allowedContentTypes ?? [.data],
            allowsMultipleSelection: false
        ) { result in
            let target = activeFileImportTarget
            isShowingFileImporter = false
            activeFileImportTarget = nil
            handleFileImportSelection(result, target: target)
        }
    }

    // Renders a tappable row for selecting a subtitle-related file.
    func subtitleSelectionButton(
        title: String,
        systemImage: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(value)
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
