import SwiftUI

// Sing mode's results on the Read tab: the note's words coloured by the last Sing session
// (heard green, missed red) and a corner badge to clear them. Shown only while the note text is
// unchanged since that session, since verdicts are keyed by offsets into it.
extension ReadView {
    // True when the Read tab should colour words by Sing verdicts instead of its usual colours.
    var isShowingSingResults: Bool {
        editModeScroll.isEditMode == false && (singSession.isActive || singSession.hasResults(for: document.text))
    }

    // Note locations of words the last Sing session heard.
    var singHeardLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value }.keys) }

    // Note locations of words the last Sing session listened for and didn't hear.
    var singMissedLocations: Set<Int> { Set(singSession.verdicts.filter { $0.value == false }.keys) }

    // Bottom-corner badge while results show: the score, and tapping clears the colours.
    @ViewBuilder
    var singResultsBadge: some View {
        if isShowingSingResults, singSession.isActive == false {
            Button {
                singSession.clearResults()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic")
                    Text("\(singHeardLocations.count)/\(singSession.verdicts.count)")
                        .monospacedDigit()
                    Image(systemName: "xmark")
                }
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.regularMaterial)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel("Sing results: \(singHeardLocations.count) of \(singSession.verdicts.count) words. Clear results.")
        }
    }
}
