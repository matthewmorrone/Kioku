import SwiftUI

// Renders the small ⓘ button placed after a control's label; tapping it opens a popover with a
// sentence or two on what that control does. Used wherever an explanation belongs to one control
// rather than a whole section (which gets a section footer instead). Borderless, so inside a Form
// row it takes its own tap instead of triggering the row's toggle, link or button.
struct InfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About this setting")
        .popover(isPresented: $isPresented) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

extension View {
    // Puts an ⓘ popover button right after this label, for a control whose label is plain text.
    func infoButton(_ text: String) -> some View {
        HStack(spacing: 6) {
            self
            InfoButton(text: text)
        }
    }
}
