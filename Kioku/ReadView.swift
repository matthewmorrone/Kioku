import SwiftUI

struct ReadView: View {
    @Binding var selectedNote: Note?
    var onActiveNoteChanged: ((UUID) -> Void)? = nil

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
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
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
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: selectedNote?.id) { _, _ in
            loadSelectedNoteIfNeeded()
        }
        .onChange(of: text) { _, _ in
            persistCurrentNoteIfNeeded()
        }
    }

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

    private func persistCurrentNoteIfNeeded() {
        guard !isLoadingSelectedNote else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty && activeNoteID == nil {
            return
        }

        var notes = loadNotesFromStorage()
        let titleToSave = customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(from: text)
            : customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackTitle = titleToSave

        if let activeNoteID, let index = notes.firstIndex(where: { $0.id == activeNoteID }) {
            notes[index].title = titleToSave
            notes[index].content = text
        } else {
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

    private func loadNotesFromStorage() -> [Note] {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else {
            return []
        }

        return decoded
    }

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

    private func firstLineTitle(from content: String) -> String {
        let firstLine = content.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine
    }
}

#Preview {
    ReadView(selectedNote: .constant(nil))
}
