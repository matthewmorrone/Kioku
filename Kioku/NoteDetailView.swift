import SwiftUI

struct NoteDetailView: View {
    @Binding var note: Note

    var body: some View {
        VStack(spacing: 12) {
            TextField("Title", text: $note.title)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $note.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
        .padding(12)
        .navigationTitle("Edit Note")
        .navigationBarTitleDisplayMode(.inline)
    }
}
