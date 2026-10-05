import SwiftUI
import UIKit

// Sing mode's strip above the transport bar in the lyrics popup: the Sing toggle, and while
// listening the Song / Line picker, the headphones note and any start-up problem. The verdict
// colours themselves are drawn by the active-cue card (LyricsView.swift) through its Saved
// Highlight slots.
extension LyricsView {
    static let singHeardColor = UIColor.systemGreen
    static let singMissedColor = UIColor.systemRed

    // Note locations of words Sing mode heard.
    var singHeardLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value }.keys) }

    // Note locations of words Sing mode listened for and didn't hear.
    var singMissedLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value == false }.keys) }

    @ViewBuilder
    var singBar: some View {
        if singRomanize != nil, cues.isEmpty == false {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Button {
                        toggleSing()
                    } label: {
                        Label(singSession.isActive ? "Stop" : "Sing", systemImage: singSession.isActive ? "mic.fill" : "mic")
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(singSession.isActive ? Color(.systemRed) : Color.primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if singSession.isActive {
                        Picker("Practice", selection: $singSession.scope) {
                            ForEach(SingScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 140)
                    }
                    Spacer(minLength: 0)
                }
                if let message = singSession.statusMessage {
                    Text(message)
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if singSession.isActive {
                    Text("Headphones recommended: the speaker leaks into the mic.")
                        .scaledFont(size: 11)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
        }
    }

    // Starts or stops listening; starting hands the session everything it needs to plan the words.
    private func toggleSing() {
        if singSession.isActive {
            singSession.stop()
            return
        }
        guard let singRomanize else { return }
        let segmentRanges = segmentationRanges.map { NSRange($0, in: noteText) }
        Task {
            await singSession.start(
                controller: controller,
                cues: cues,
                noteText: noteText,
                highlightRanges: highlightRanges,
                segmentRanges: segmentRanges,
                romanize: singRomanize
            )
        }
    }
}
