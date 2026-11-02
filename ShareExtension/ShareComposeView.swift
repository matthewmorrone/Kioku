import SwiftUI

// The share sheet's screen. Layout: a toolbar with Cancel and Save, an optional title field, then
// the shared text (editable) or the shared link (read-only, with a note that its page text is
// fetched when Kioku opens).
struct ShareComposeView: View {
    let shared: SharedContent
    let onSave: (SharedInboxItem) -> Void
    let onCancel: () -> Void

    @State private var title = ""
    @State private var text: String

    init(shared: SharedContent, onSave: @escaping (SharedInboxItem) -> Void, onCancel: @escaping () -> Void) {
        self.shared = shared
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: shared.text ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (optional)", text: $title)
                }
                if let url = shared.url {
                    Section {
                        Text(url)
                            .font(.callout)
                            .textSelection(.enabled)
                    } footer: {
                        Text("The page's text is added as a note the next time you open Kioku.")
                    }
                } else if shared.text != nil {
                    Section {
                        TextEditor(text: $text)
                            .frame(minHeight: 180)
                    }
                } else {
                    Section {
                        Text("Nothing readable was shared.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(canSave == false)
                }
            }
        }
    }

    // Saving needs text to keep or a link to fetch.
    private var canSave: Bool {
        shared.url != nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    // Packages the screen's state for the inbox: the link as shared, or the (possibly edited) text.
    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = shared.url {
            onSave(SharedInboxItem(title: trimmedTitle, url: url))
        } else {
            onSave(SharedInboxItem(title: trimmedTitle, text: text))
        }
    }
}
