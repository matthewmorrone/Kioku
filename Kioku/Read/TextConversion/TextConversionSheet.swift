import SwiftUI

// Review sheet for the Read tab's Cleanup (English → katakana, width normalization). Lists
// every run found in the note with its proposed replacement; each row can be switched off or its
// replacement edited before anything is written. Layout: a top bar (Cancel · All/None · Apply),
// then one row per proposal — accept checkmark, the original, and an editable replacement field.
struct TextConversionSheet: View {
    @Binding var proposals: [TextConversion]
    let onApply: () -> Void
    let onCancel: () -> Void

    private var acceptedCount: Int { proposals.filter(\.isAccepted).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(acceptedCount == proposals.count ? "None" : "All") {
                    let target = acceptedCount != proposals.count
                    for i in proposals.indices { proposals[i].isAccepted = target }
                }
                Spacer()
                Button("Apply \(acceptedCount)", action: onApply)
                    .fontWeight(.semibold)
                    .disabled(acceptedCount == 0)
            }
            .padding()

            List {
                ForEach($proposals) { $proposal in
                    HStack(spacing: 12) {
                        Button {
                            proposal.isAccepted.toggle()
                        } label: {
                            Image(systemName: proposal.isAccepted ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundStyle(proposal.isAccepted ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(proposal.isAccepted ? "Skip \(proposal.original)" : "Convert \(proposal.original)")

                        VStack(alignment: .leading, spacing: 4) {
                            Text(proposal.original)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("", text: $proposal.replacement)
                                .font(.title3)
                                .disabled(proposal.isAccepted == false)
                        }
                    }
                    .opacity(proposal.isAccepted ? 1 : 0.5)
                }
            }
            .listStyle(.plain)
        }
    }
}
