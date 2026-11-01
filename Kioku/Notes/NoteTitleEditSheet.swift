import SwiftUI

// Small sheet for editing a note's title, used by the Read tab and the Notes list. It replaces an
// alert because an alert's text field can't show the clear ("x") button on its right edge.
// Layout: heading, one text field with a trailing clear button, Cancel / Save row.
struct NoteTitleEditSheet: View {
    @Binding var title: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Title")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("Title", text: $title)
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(onSave)
                if title.isEmpty == false {
                    Button {
                        title = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Title")
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Save", action: onSave)
                    .fontWeight(.semibold)
            }
        }
        .padding(20)
        .presentationDetents([.height(200)])
        .onAppear { isFocused = true }
    }
}
