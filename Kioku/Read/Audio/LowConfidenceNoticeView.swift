import SwiftUI

// The sheet shown after an alignment whose lines don't sound like their lyrics (AlignmentConfidence): how
// many lines, a plain OK, and a small "don't show again for this song" checkbox underneath. Layout:
// title, message, OK button, checkbox row. Presented from ReadView's lifecycle modifiers.
struct LowConfidenceNoticeView: View {
    let weakLines: Int
    let scoredLines: Int
    @Binding var dontShowAgain: Bool
    let onOK: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Alignment May Be Off")
                .font(.headline)
            Text("\(weakLines) of \(scoredLines) lines don't sound like their lyrics where they are placed. The lyrics may differ from what is sung, or the timing may be off.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("OK", action: onOK)
                .buttonStyle(.borderedProminent)
            Button {
                dontShowAgain.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: dontShowAgain ? "checkmark.square.fill" : "square")
                    Text("Don't show again for this song")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .presentationDetents([.height(280)])
    }
}
