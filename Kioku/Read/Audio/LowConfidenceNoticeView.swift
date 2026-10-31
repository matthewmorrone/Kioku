import SwiftUI

// The sheet shown after an alignment the aligner isn't confident in (AlignmentConfidence): the
// percent, a plain OK, and a small "don't show again for this song" checkbox underneath. Layout:
// title, message, OK button, checkbox row. Presented from ReadView's lifecycle modifiers.
struct LowConfidenceNoticeView: View {
    let percent: Int
    @Binding var dontShowAgain: Bool
    let onOK: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Alignment May Be Off")
                .font(.headline)
            Text("The aligner is only \(percent)% confident in this alignment. The lyrics may differ from what is sung, or the vocals may be unclear.")
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
