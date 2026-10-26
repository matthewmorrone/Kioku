import SwiftUI

// The "Changes from Default" prompt the Read toolbar's reset button opens: what the user changed from
// Kioku's own segmentation, with Reset to drop it. Drawn as a card over a dimmed backdrop, not a system
// alert, so a tap outside the card closes it. Layout: dimmed full-screen backdrop (tap closes), then a
// centred card — title, one line per change (or "None"), and the Reset / Cancel buttons (or OK alone).
struct ChangesFromDefaultCard: View {
    // One line per difference from the computed segmentation; empty means nothing to reset.
    let changes: [String]
    // Resets segmentation to the computed one.
    let onReset: () -> Void
    // Closes the card without resetting.
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 14) {
                Text("Changes from Default")
                    .font(.headline)
                Text(changes.isEmpty ? "None" : changes.joined(separator: "\n"))
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if changes.isEmpty {
                    Button("OK", action: onClose)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    HStack(spacing: 12) {
                        Button("Cancel", action: onClose)
                            .frame(maxWidth: .infinity)
                        Button("Reset", role: .destructive) {
                            onReset()
                            onClose()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(radius: 20)
        }
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
    }
}
