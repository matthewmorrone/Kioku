import SwiftUI

// Sheet for importing a web page as a Note. User pastes a URL; we fetch and convert the HTML
// to plaintext via URLTextImporter, then hand the resulting Note to the existing OCR-imported-note
// callback (the downstream flow is identical: add to store + jump to Read tab in edit mode).
// Owned by NotesView; presented from the OCR menu's "From URL" option.
struct URLImportSheet: View {
    let onImported: (Note) -> Void

    @State private var urlString: String = ""
    @State private var isFetching = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("URL") {
                    TextField("https://www3.nhk.or.jp/news/easy/…", text: $urlString)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .onSubmit { fetch() }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        fetch()
                    } label: {
                        HStack {
                            if isFetching {
                                ProgressView().controlSize(.small)
                                Text("Fetching…")
                            } else {
                                Label("Fetch and Import", systemImage: "arrow.down.doc")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isFetching || urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("Fetches the page, extracts the visible text, and creates a new note from it. Works best on article-like pages (NHK News Easy, blogs); pages with heavy navigation may need trimming in the editor.")
                        .font(.caption)
                }
            }
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isFetching)
                }
            }
        }
    }

    // Fetches the URL via URLTextImporter and, on success, hands a fresh Note to the parent.
    private func fetch() {
        let candidate = urlString
        errorMessage = nil
        isFetching = true
        Task {
            do {
                let text = try await URLTextImporter.extractText(from: candidate)
                let note = Note(content: text)
                isFetching = false
                onImported(note)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isFetching = false
            }
        }
    }
}
