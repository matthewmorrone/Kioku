import SwiftUI

// Alert with a text field for naming a new folder or renaming one. Pulled out of NotesView's
// modifier chain, which is already close to the type-checker's limit.
struct NoteFolderNameAlert: ViewModifier {
    @Binding var editor: NoteFolderEditor?
    @Binding var draft: String
    let onCommit: (NoteFolderEditor, String) -> Void

    // Presents the alert while `editor` is set; Save hands the typed name back, Cancel just clears it.
    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented) {
            TextField("Folder name", text: $draft)
            Button("Cancel", role: .cancel) { editor = nil }
            Button("Save") {
                if let editor { onCommit(editor, draft) }
                editor = nil
            }
        }
    }

    private var title: String {
        if case .rename = editor { return "Rename Folder" }
        return "New Folder"
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { editor != nil },
            set: { if $0 == false { editor = nil } }
        )
    }
}
