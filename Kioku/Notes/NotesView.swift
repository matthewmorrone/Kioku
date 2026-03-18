import SwiftUI

// Displays the notes list and supports selection, editing, and creation actions.
struct NotesView: View {
    var onSelectNote: ((Note) -> Void)? = nil
    var onCreateNote: (() -> Void)? = nil
    var onUpdateSelectedNote: ((Note?) -> Void)? = nil

    @EnvironmentObject private var store: NotesStore
    @State private var editMode: EditMode = .inactive
    @State private var selectedNoteIDs = Set<UUID>()
    @State private var notePendingRename: Note?
    @State private var notePendingReset: Note?
    @State private var notePendingDelete: Note?
    @State private var renameDraft = ""
    @State private var isShowingSubtitleImportSheet = false
    @State private var subtitleImportError = ""

    var body: some View {
        NavigationStack {
            // Displays the selectable/reorderable list of notes.
            List(selection: $selectedNoteIDs) {
                ForEach(store.notes) { note in
                    // Renders a single note row with title and content preview.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : note.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(note.content)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        noteContextMenu(for: note)
                    }
                    .onTapGesture {
                        if editMode == .active {
                            if selectedNoteIDs.contains(note.id) {
                                selectedNoteIDs.remove(note.id)
                            } else {
                                selectedNoteIDs.insert(note.id)
                            }
                        } else {
                            onSelectNote?(note)
                        }
                    }
                    .tag(note.id)
                    .deleteDisabled(editMode == .active)
                }
                .onMove(perform: store.moveNotes)
                .onDelete(perform: store.deleteNotes)
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                store.reload()
            }
            .onChange(of: editMode) { _, newValue in
                if newValue == .inactive {
                    selectedNoteIDs.removeAll()
                }
            }
            .alert("Rename Note", isPresented: renameAlertPresented) {
                TextField("Title", text: $renameDraft)
                Button("Cancel", role: .cancel) {
                    notePendingRename = nil
                }
                Button("Save") {
                    commitRename()
                }
            }
            .confirmationDialog(
                "Reset Note?",
                isPresented: resetDialogPresented,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    confirmReset()
                }
                Button("Cancel", role: .cancel) {
                    notePendingReset = nil
                }
            } message: {
                Text("This clears the note title, content, and saved segmentation units.")
            }
            .confirmationDialog(
                "Delete Note?",
                isPresented: deleteDialogPresented,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    confirmDelete()
                }
                Button("Cancel", role: .cancel) {
                    notePendingDelete = nil
                }
            } message: {
                Text("This permanently removes the note.")
            }
            .sheet(isPresented: $isShowingSubtitleImportSheet) {
                SubtitleImportSheet { cues, audioURL in
                    handleSubtitleImport(cues: cues, audioURL: audioURL)
                }
            }
            .alert("Subtitle Import Failed", isPresented: subtitleImportErrorBinding) {
                Button("OK", role: .cancel) { subtitleImportError = "" }
            } message: {
                Text(subtitleImportError)
            }
            .toolbar {
                // Opens the subtitle import sheet so the user can create a note from subtitles.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSubtitleImportSheet = true
                    } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Import Subtitles")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Shows bulk-delete action while edit mode is active.
                    if editMode == .active {
                        Button {
                            store.deleteNotes(ids: selectedNoteIDs)
                            selectedNoteIDs.removeAll()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 16))
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Delete Selected Notes")
                        .disabled(selectedNoteIDs.isEmpty)
                    }

                    // Toggles multi-select editing mode for list operations.
                    Button {
                        editMode = editMode == .active ? .inactive : .active
                    } label: {
                        Image(systemName: editMode == .active ? "checkmark.circle" : "pencil")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(editMode == .active ? "Done Editing" : "Edit All")

                    // Creates a new note using callback override or store default behavior.
                    Button {
                        if let onCreateNote {
                            onCreateNote()
                        } else {
                            store.addNote()
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("New Note")
                }
            }
            .environment(\.editMode, $editMode)
        }
        .toolbar(.visible, for: .tabBar)
    }

    // Binds subtitle-import error alert to whether there is currently a failure message.
    private var subtitleImportErrorBinding: Binding<Bool> {
        Binding(
            get: { subtitleImportError.isEmpty == false },
            set: { isPresented in
                if isPresented == false {
                    subtitleImportError = ""
                }
            }
        )
    }

    // Creates a note from parsed subtitle cues, optionally saving audio and cue timing data.
    private func handleSubtitleImport(cues: [SubtitleCue], audioURL: URL?) {
        let content = SubtitleParser.assembleNoteContent(from: cues)
        let title = String(content.prefix(60)).components(separatedBy: "\n").first ?? ""

        var attachmentID: UUID? = nil

        if let audioURL {
            let newID = UUID()
            do {
                _ = try NotesAudioStore.shared.saveAudio(from: audioURL, attachmentID: newID)
                try NotesAudioStore.shared.saveCues(cues, attachmentID: newID)
                attachmentID = newID
            } catch {
                subtitleImportError = error.localizedDescription
                return
            }
        }

        let newNote = Note(
            title: title,
            content: content,
            audioAttachmentID: attachmentID
        )
        store.addNote(newNote)
        onSelectNote?(newNote)
    }

    // Binds rename-alert presentation directly to the currently pending note.
    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { notePendingRename != nil },
            set: { isPresented in
                if isPresented == false {
                    notePendingRename = nil
                }
            }
        )
    }

    // Binds reset-dialog presentation directly to the currently pending note.
    private var resetDialogPresented: Binding<Bool> {
        Binding(
            get: { notePendingReset != nil },
            set: { isPresented in
                if isPresented == false {
                    notePendingReset = nil
                }
            }
        )
    }

    // Binds delete-dialog presentation directly to the currently pending note.
    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { notePendingDelete != nil },
            set: { isPresented in
                if isPresented == false {
                    notePendingDelete = nil
                }
            }
        )
    }

    // Builds the per-note context menu shown from the notes list.
    @ViewBuilder
    private func noteContextMenu(for note: Note) -> some View {
        Button {
            notePendingRename = note
            renameDraft = resolvedTitle(for: note)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            duplicate(note)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }

        ShareLink(
            item: shareText(for: note),
            subject: Text(resolvedTitle(for: note)),
            message: Text("Shared from Kioku")
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Button {
            notePendingReset = note
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }

        Button(role: .destructive) {
            notePendingDelete = note
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // Commits the rename request for the pending note and updates any active read selection.
    private func commitRename() {
        guard let notePendingRename else {
            return
        }

        store.renameNote(id: notePendingRename.id, title: renameDraft)
        onUpdateSelectedNote?(store.note(withID: notePendingRename.id))
        self.notePendingRename = nil
    }

    // Resets one note after confirmation and propagates the updated value to the read screen if needed.
    private func confirmReset() {
        guard let notePendingReset else {
            return
        }

        store.resetNote(id: notePendingReset.id)
        onUpdateSelectedNote?(store.note(withID: notePendingReset.id))
        self.notePendingReset = nil
    }

    // Deletes one note after confirmation and clears the active read selection when that note was selected.
    private func confirmDelete() {
        guard let notePendingDelete else {
            return
        }

        selectedNoteIDs.remove(notePendingDelete.id)
        let deletedNote = store.deleteNote(id: notePendingDelete.id)
        if deletedNote != nil {
            onUpdateSelectedNote?(nil)
        }
        self.notePendingDelete = nil
    }

    // Inserts a duplicated note at the top of the list and keeps the active note in sync when appropriate.
    private func duplicate(_ note: Note) {
        guard let duplicatedNote = store.duplicateNote(id: note.id) else {
            return
        }

        onUpdateSelectedNote?(store.note(withID: duplicatedNote.id))
    }

    // Resolves a presentable note title for menu labels and shared text subjects.
    private func resolvedTitle(for note: Note) -> String {
        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Untitled Note" : trimmedTitle
    }

    // Builds the shared plain-text representation for a single note export.
    private func shareText(for note: Note) -> String {
        let title = resolvedTitle(for: note)
        let trimmedContent = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty {
            return title
        }

        return "\(title)\n\n\(note.content)"
    }
}

#Preview {
    ContentView(selectedTab: .notes)
}
