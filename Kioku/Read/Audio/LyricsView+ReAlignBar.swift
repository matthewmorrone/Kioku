import SwiftUI
import SwiftWhisperAlign

// Top action bar for the karaoke view: Re-align (one forced-alignment pass over the whole song;
// press and hold for Re-align from Scratch, which isolates the vocals again first) and the
// settings-popup gear (LyricsView+SettingsPopup.swift). Not private: called from panel(geo:) in
// LyricsView.swift.
extension LyricsView {
    // The attached song's audio file, which keys its cached vocal stem.
    private var attachmentAudioURL: URL? {
        attachmentID.flatMap { NotesAudioStore.shared.audioURL(for: $0) }
    }

    // Re-align button (or its live progress chip while a run is in flight), plus the gear that
    // opens the in-place settings popup.
    func reAlignBar() -> some View {
        HStack(spacing: 8) {
            if isReAligning {
                // The progress chip is the button while a run is in flight: tapping it asks
                // before cancelling. `.primary` keeps the status text high-contrast over the bar.
                Button {
                    isShowingCancelReAlignConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(reAlignMessage.isEmpty ? "Re-aligning…" : reAlignMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isCancellingReAlign)
                .accessibilityLabel(reAlignMessage.isEmpty ? "Re-aligning, tap to cancel" : "\(reAlignMessage), tap to cancel")
                .confirmationDialog("Cancel alignment?", isPresented: $isShowingCancelReAlignConfirm, titleVisibility: .visible) {
                    Button("Cancel Alignment", role: .destructive) { onCancelReAlign() }
                    Button("Keep Going", role: .cancel) { }
                }
            } else {
                Button {
                    onReAlign()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 12, weight: .semibold))
                        Text(cues.isEmpty ? "Align" : "Re-align")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 16)
                    .frame(height: 28)
                    .background(Color.accentColor.opacity(0.16))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(cues.isEmpty ? "Align all lyrics to the audio" : "Re-align all lyrics to the audio")
                .contextMenu {
                    Button("Re-align from Scratch", systemImage: "arrow.clockwise") {
                        if let audioURL = attachmentAudioURL { VocalStemCache.delete(for: audioURL) }
                        onReAlign()
                    }
                    .disabled(attachmentAudioURL.map(VocalStemCache.hasStem(for:)) != true)
                }
            }

            Spacer(minLength: 0)

            Button {
                isShowingSettingsPopup = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.secondary.opacity(0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lyrics Settings")
            .popover(isPresented: $isShowingSettingsPopup) {
                settingsPopup
                    .presentationCompactAdaptation(.popover)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.18))
    }
}
