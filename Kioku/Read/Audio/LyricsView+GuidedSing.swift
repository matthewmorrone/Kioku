import SwiftUI

// Guided Sing's controls in the lyrics popup: the Guided capsule beside Sing that starts it, and
// the line bar under the Sing row while it runs — an instruction saying what to do now (listen,
// sing the line, say the named words, or which words were missed), then previous line, the
// step's action (Done / Hear it again), next line, and what the mic heard under it.
// The words themselves turn green and red on the lyrics card as they're graded.
extension LyricsView {
    @ViewBuilder
    var guidedSingButton: some View {
        Button {
            toggleSing(guided: true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2")
                    .scaledFont(size: 12, weight: .semibold)
                Text("Guided")
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.secondary.opacity(0.16))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Guided sing: hear each line, then repeat it")
    }

    @ViewBuilder
    var guidedSingBar: some View {
        let phase = singSession.guidedPhase
        VStack(spacing: 6) {
            Text(guidedInstruction)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(phase == .yourTurn ? Color(.systemRed) : Color.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                guidedIconButton("chevron.left", label: "Previous line", enabled: singSession.guidedHasPrevious) {
                    singSession.guidedStep(by: -1)
                }
                Spacer(minLength: 0)
                switch phase {
                case .yourTurn:
                    guidedTextButton("Done", systemName: "checkmark") { singSession.guidedFinishTurn() }
                case .review:
                    guidedTextButton("Hear it again", systemName: "speaker.wave.2") { singSession.guidedReplay() }
                case .listening, nil:
                    EmptyView()
                }
                Spacer(minLength: 0)
                guidedIconButton("chevron.right", label: "Next line", enabled: singSession.guidedHasNext) {
                    singSession.guidedStep(by: 1)
                }
            }
            // What the mic picked up this turn, so a miss shows what was heard instead.
            if phase != .listening, singSession.guidedHeard.isEmpty == false {
                Text("Heard: \(singSession.guidedHeard)")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    // One sentence telling the singer what to do now: listen, sing the line (or just the words
    // being retried, named), or what was missed before the mic listens for those again.
    private var guidedInstruction: String {
        let heard = singSession.guidedLineHeardCount, total = singSession.guidedLineWordCount
        switch singSession.guidedPhase {
        case .listening:
            return "Listen to this line…"
        case .yourTurn:
            let pending = singSession.guidedPending
            guard pending.isEmpty == false, pending.count < total else {
                return "Your turn: sing the line now (\(heard)/\(total) heard)"
            }
            return "Your turn: say " + guidedSurfaces(of: pending).joined(separator: " ")
        case .review:
            let missed = singSession.guidedCueIndex.map { singSession.guidedMissed(in: $0) } ?? []
            if missed.isEmpty {
                return heard == total && total > 0 ? "All heard!" : "Tap Hear it again to start this line"
            }
            return "Missed: " + guidedSurfaces(of: missed).joined(separator: " ")
        case nil:
            return ""
        }
    }

    // A labelled capsule button for the bar's main actions.
    private func guidedTextButton(_ title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .scaledFont(size: 12, weight: .semibold)
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.accentColor.opacity(0.16))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // The note text of the words starting at `locations`, in line order, for the retry prompt.
    private func guidedSurfaces(of locations: Set<Int>) -> [String] {
        let noteNS = noteText as NSString
        let words = segmentationRanges.map { NSRange($0, in: noteText) }
        return locations.sorted().compactMap { location in
            guard let word = words.first(where: { NSLocationInRange(location, $0) }), NSMaxRange(word) <= noteNS.length else { return nil }
            return noteNS.substring(with: NSRange(location: location, length: NSMaxRange(word) - location))
        }
    }

    // One round capsule button in the guided bar.
    private func guidedIconButton(_ systemName: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 36, height: 28)
                .background((enabled ? Color.accentColor : Color.secondary).opacity(0.16))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(enabled == false)
        .accessibilityLabel(label)
    }
}
