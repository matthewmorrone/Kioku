import SwiftUI

// Provides the primary reading and editing surface for an active note.
struct ReadView: View {
    @Binding var selectedNote: Note?
    let segmenter: Segmenter
    var onActiveNoteChanged: ((UUID) -> Void)? = nil

    @AppStorage(TypographySettings.textSizeKey) 
    private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) 
    private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) 
    private var kerning = TypographySettings.defaultKerning

    @State private var customTitle = ""
    @State private var fallbackTitle = ""
    @State private var titleDraft = ""
    @State private var isShowingTitleAlert = false
    @State private var text = ""
    @State private var activeNoteID: UUID?
    @State private var isLoadingSelectedNote = false

    private let storageKey = "kioku.notes.v1"

    var body: some View {
        NavigationStack {
            // Displays the editable note title at the top of the reading screen.
            Text(displayTitle)
                .font(.system(size: 24, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .onTapGesture {
                    titleDraft = resolvedTitle
                    isShowingTitleAlert = true
                }
                .alert("Edit Title", isPresented: $isShowingTitleAlert) {
                    TextField("Title", text: $titleDraft)
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        customTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        persistCurrentNoteIfNeeded()
                    }
                }
            VStack(spacing: 10) {
                // Displays the main text editing surface for note content.
                RichTextEditor(
                    text: $text,
                    textSize: $textSize,
                    lineSpacing: lineSpacing,
                    kerning: kerning
                )
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .toolbar(.visible, for: .tabBar)
        .onAppear {
            // Syncs editor state when this screen first appears.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: selectedNote?.id) { _, _ in
            // Syncs editor state when Notes tab selects a different note.
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: text) { _, _ in
            // Persists edits as content changes.
            persistCurrentNoteIfNeeded()
            // Prints the current segmentation lattice while the user edits text.
            if !isLoadingSelectedNote {
                segmenter.debugPrintLattice(for: text)
            }
        }
    }

    // Loads the selected note into editor state when navigation targets change.
    private func loadSelectedNoteIfNeeded() {
        guard let selectedNote else { return }
        isLoadingSelectedNote = true
        activeNoteID = selectedNote.id
        onActiveNoteChanged?(selectedNote.id)
        customTitle = selectedNote.title
        fallbackTitle = selectedNote.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: selectedNote.content)
            : selectedNote.title
        text = selectedNote.content
        self.selectedNote = nil
        isLoadingSelectedNote = false
    }

    // Saves the in-memory editor state to storage and maintains active note identity.
    private func persistCurrentNoteIfNeeded() {
        guard !isLoadingSelectedNote else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Avoid creating an empty note when the editor has no active note yet.
        if trimmedText.isEmpty && activeNoteID == nil {
            return
        }

        var notes = loadNotesFromStorage()
        // Prefer explicit titles; otherwise derive one from first content line.
        let titleToSave = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: text)
            : customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackTitle = titleToSave

        if let activeNoteID, let index = notes.firstIndex(where: { $0.id == activeNoteID }) {
            // Update the existing note in place when editing an active item.
            notes[index].title = titleToSave
            notes[index].content = text
        } else {
            // Insert a new note only when no active note identity exists.
            let newNote = Note(title: titleToSave, content: text)
            notes.insert(newNote, at: 0)
            activeNoteID = newNote.id
            onActiveNoteChanged?(newNote.id)
        }

        if let activeNoteID {
            onActiveNoteChanged?(activeNoteID)
        }

        saveNotesToStorage(notes)
    }

    // Reads note payloads from user defaults storage.
    private func loadNotesFromStorage() -> [Note] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else {
            return []
        }

        return decoded
    }

    // Writes note payloads to user defaults storage.
    private func saveNotesToStorage(_ notes: [Note]) {
        guard let encoded = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }

    private var resolvedTitle: String {
        let trimmedCustom = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }

        return fallbackTitle
    }

    private var displayTitle: String {
        resolvedTitle.isEmpty ? " " : resolvedTitle
    }

    // Derives a fallback title from the first line of note content.
    private func firstLineTitle(from content: String) -> String {
        let firstLine = content.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine
    }
}

#Preview {
    ReadView(selectedNote: .constant(nil), segmenter: Segmenter(trie: DictionaryTrie()))
}
