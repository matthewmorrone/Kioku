import SwiftUI
import UIKit

// Sing mode's controls in the lyrics popup's top bar: the Sing capsule (beside the Mix / Vocals /
// Instrumental one), and while listening the Line / Song capsule; plus the brief notice line
// under the bar (headphones advice, or why Sing couldn't start). The verdict colours themselves
// are drawn by the active-cue card (LyricsView.swift) through its Saved Highlight slots.
extension LyricsView {
    static let singHeardColor = UIColor.systemGreen
    static let singMissedColor = UIColor.systemRed

    // Note locations of words Sing mode heard.
    var singHeardLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value }.keys) }

    // Note locations of words Sing mode listened for and didn't hear.
    var singMissedLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value == false }.keys) }

    @ViewBuilder
    var singControls: some View {
        Button {
            toggleSing()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: singSession.isActive ? "mic.fill" : "mic")
                    .scaledFont(size: 12, weight: .semibold)
                Text(singSession.isActive ? "Singing" : "Sing")
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(singSession.isActive ? Color(.systemRed) : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background((singSession.isActive ? Color(.systemRed) : Color.secondary).opacity(0.16))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(singSession.isActive ? "Stop singing" : "Sing along")

        if singSession.isActive {
            Button {
                singSession.scope = singSession.scope == .song ? .line : .song
            } label: {
                Image(systemName: singSession.scope == .line ? "repeat.1" : "repeat")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(singSession.scope == .line ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background((singSession.scope == .line ? Color.accentColor : Color.secondary).opacity(0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(singSession.scope == .line ? "Looping this line. Tap to sing the whole song." : "Singing the whole song. Tap to loop this line.")
        }
    }

    // One line under the top bar: a start-up problem, or the headphones advice for a few seconds.
    @ViewBuilder
    var singNotice: some View {
        if let message = singSession.statusMessage ?? (singSession.isShowingHeadphonesNotice ? "Headphones recommended: the speaker leaks into the mic." : nil) {
            Text(message)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .transition(.opacity)
        }
    }

    // Starts or stops listening. Starting switches playback to the instrumental and stopping puts
    // back whatever was playing before.
    private func toggleSing() {
        if singSession.isActive {
            if let previous = singSession.restoreAudioSource { onSetAudioSource(previous) }
            singSession.stop()
            return
        }
        guard let singRomanize else { return }
        let segmentRanges = segmentationRanges.map { NSRange($0, in: noteText) }
        let previous = audioSource
        Task {
            await singSession.start(
                controller: controller,
                cues: cues,
                noteText: noteText,
                highlightRanges: highlightRanges,
                segmentRanges: segmentRanges,
                romanize: singRomanize
            )
            guard singSession.isActive else { return }
            singSession.restoreAudioSource = previous
            onSetAudioSource(.instrumental)
        }
    }
}
