import SwiftUI

// Floating bottom prompt shown when a new clipboard string is available for dictionary lookup.
// Owned by ContentView; renders above the tab bar via .overlay(alignment: .bottom).
struct ClipboardLookupBanner: View {
    let onLookup: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Clipboard updated")
                    .font(.callout.weight(.medium))
                Text("Look it up in the dictionary?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Lookup", action: onLookup)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss clipboard lookup")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .floatingGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), shadowOpacity: 0.12)
    }
}
