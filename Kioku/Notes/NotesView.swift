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
    @State private var notePendingDelete: Note?
    @State private var renameDraft = ""
    @State private var isShowingBulkImportSheet = false
    @State private var subtitleEditorAttachmentID: UUID?
    @State private var subtitleEditorNoteTitle: String = ""

    var body: some View {
        NavigationStack {
            // Displays the selectable/reorderable list of notes.
            List(selection: $selectedNoteIDs) {
                ForEach(store.notes) { note in
                    // Renders a single note row with title and content preview.
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : note.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(note.content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        noteAttachmentIndicators(for: note)
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
            .sheet(isPresented: $isShowingBulkImportSheet) {
                BulkImportSheet(store: store)
                    .environmentObject(store)
            }
            .sheet(item: Binding(
                get: { subtitleEditorAttachmentID.map { SubtitleEditorPresentation(attachmentID: $0) } },
                set: { newValue in subtitleEditorAttachmentID = newValue?.attachmentID }
            )) { presentation in
                let cues = NotesAudioStore.shared.loadCues(for: presentation.attachmentID)
                SubtitleEditorSheet(
                    attachmentID: presentation.attachmentID,
                    initialCues: cues,
                    noteText: subtitleEditorNoteTitle,
                    onSave: { updated in
                        try? NotesAudioStore.shared.saveCues(updated, attachmentID: presentation.attachmentID)
                    }
                )
            }
            .toolbar {
                // Groups the two leading import entry points so SwiftUI renders both buttons
                // (single ToolbarItems at the same placement can silently collapse to one).
                ToolbarItem(placement: .topBarLeading) {
                    // Opens the bulk import sheet so the user can pick txt/srt/audio files. Single
                    // and multi-file flows both run through here; audio-only items get Whisper
                    // transcription via BulkImportRunner.
                    Button {
                        isShowingBulkImportSheet = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("Import Files")
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

    // Shows whether a note currently has stored audio and/or subtitle files attached.
    @ViewBuilder
    private func noteAttachmentIndicators(for note: Note) -> some View {
        let attachmentState = attachmentState(for: note)

        if attachmentState.hasAudio || attachmentState.hasSubtitles {
            HStack(spacing: 8) {
                if attachmentState.hasAudio {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Has audio")
                }

                if attachmentState.hasSubtitles {
                    Image(systemName: "captions.bubble")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Has subtitles")
                }
            }
            .font(.system(size: 14, weight: .medium))
        }
    }

    // Resolves attachment state from the note's stored attachment identifier and on-disk files.
    private func attachmentState(for note: Note) -> (hasAudio: Bool, hasSubtitles: Bool) {
        guard let attachmentID = note.audioAttachmentID else {
            return (false, false)
        }

        return (
            hasAudio: NotesAudioStore.shared.audioURL(for: attachmentID) != nil,
            hasSubtitles: NotesAudioStore.shared.subtitleURL(for: attachmentID) != nil
        )
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

        if let attachmentID = note.audioAttachmentID {
            Button {
                subtitleEditorNoteTitle = note.content
                subtitleEditorAttachmentID = attachmentID
            } label: {
                Label("Edit Subtitles", systemImage: "captions.bubble")
            }

            Button(role: .destructive) {
                resetSubtitleAttachment(for: note)
            } label: {
                Label("Reset Subtitles", systemImage: "captions.bubble.fill")
            }
        }

        Button {
            store.resetNote(id: note.id)
            onUpdateSelectedNote?(store.note(withID: note.id))
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }

        Button(role: .destructive) {
            notePendingDelete = note
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // Detaches the audio + subtitles from a note: deletes the on-disk attachment files and clears
    // the audioAttachmentID. Selected-note state is refreshed via the onUpdateSelectedNote callback.
    private func resetSubtitleAttachment(for note: Note) {
        guard let attachmentID = note.audioAttachmentID else { return }
        NotesAudioStore.shared.deleteAttachment(attachmentID)
        store.updateAudioAttachment(id: note.id, attachmentID: nil)
        onUpdateSelectedNote?(store.note(withID: note.id))
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

// Identifiable wrapper so the SubtitleEditorSheet can be presented via .sheet(item:) from the
// context menu — Identifiable conformance is required by the sheet-item modifier.
private struct SubtitleEditorPresentation: Identifiable {
    var attachmentID: UUID
    var id: UUID { attachmentID }
}

#Preview {
    ContentView(selectedTab: .notes)
}
