import PhotosUI
import SwiftUI

// Displays the notes list and supports selection, editing, and creation actions.
//
// OCR import is fully owned by this tab — button, picker, Vision recognition, and note
// creation all live here. When OCR finishes a recognized note is forwarded via
// `onOCRImportedNote` so ContentView can add it to the store, mark it the active Read
// note, switch to the Read tab, and arm edit mode (mirroring the previous Read-side
// flow's end state).
struct NotesView: View {
    var onSelectNote: ((Note) -> Void)? = nil
    var onCreateNote: (() -> Void)? = nil
    var onUpdateSelectedNote: ((Note?) -> Void)? = nil
    var onOCRImportedNote: ((Note) -> Void)? = nil

    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var wordsStore: WordsStore
    @State private var editMode: EditMode = .inactive
    @State private var selectedNoteIDs = Set<UUID>()
    @State private var notePendingRename: Note?
    // Notes awaiting delete confirmation (single, swipe, or bulk). `title` is set only for a
    // single-note delete so the dialog can name it; nil for a multi-note delete.
    @State private var pendingDeletion: PendingNoteDeletion?
    @State private var renameDraft = ""
    @State private var isShowingBulkImportSheet = false
    @State private var subtitleEditorAttachmentID: UUID?
    @State private var subtitleEditorNoteTitle: String = ""

    // OCR state owned by NotesView. Declared here (not in the extension) because Swift
    // extensions on structs cannot add stored properties — only the helpers and the
    // toolbar button view go in NotesView+OCR.swift.
    @State var isShowingPhotoLibraryPicker = false
    @State var isShowingCameraPicker = false
    @State var selectedOCRImageItem: PhotosPickerItem?
    @State var isPerformingOCRImport = false
    @State var ocrImportErrorMessage = ""
    @State var isShowingURLImportSheet = false

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
                    // Anchored to THIS row: presents only when this note is the single pending
                    // deletion, so the popover arrow points here rather than at a default row.
                    .confirmationDialog(
                        deleteDialogTitle,
                        isPresented: rowDeletePresented(note),
                        titleVisibility: .visible
                    ) {
                        Button("Delete Note", role: .destructive) {
                            performDelete()
                        }
                        Button("Cancel", role: .cancel) {
                            pendingDeletion = nil
                        }
                    } message: {
                        Text(deleteDialogMessage)
                    }
                }
                .onMove(perform: store.moveNotes)
                .onDelete { offsets in
                    // Route swipe-to-delete through the same confirmation so the associated-word
                    // offer applies here too (it previously deleted immediately).
                    let notes = offsets.map { store.notes[$0] }
                    pendingDeletion = PendingNoteDeletion(
                        noteIDs: Set(notes.map(\.id)),
                        title: notes.count == 1 ? resolvedTitle(for: notes[0]) : nil
                    )
                }
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
            // Multi-note deletes (toolbar / Edit mode) have no source row to anchor to, so they use
            // a top-level dialog. Single-note deletes are confirmed per-row (see rowDeletePresented)
            // so the popover arrow points at the note being deleted.
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: bulkDeleteDialogPresented,
                titleVisibility: .visible
            ) {
                Button("Delete Note\(pendingNoteCountSuffix)", role: .destructive) {
                    performDelete()
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: {
                Text(deleteDialogMessage)
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
                // Leading group: file-based and image-based import entry points sit together
                // on the left so the user reads "import sources" → "selection/editing" → "new"
                // from left to right across the toolbar.
                ToolbarItemGroup(placement: .topBarLeading) {
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

                    // OCR import (Camera or Photo Library). Runs Vision recognition locally
                    // on Notes and hands the recognized Note to ContentView via
                    // `onOCRImportedNote` for tab-switch + edit-mode activation.
                    ocrImportToolbarButton
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Shows bulk-delete action while edit mode is active.
                    if editMode == .active {
                        Button {
                            pendingDeletion = PendingNoteDeletion(noteIDs: selectedNoteIDs, title: nil)
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
            // OCR plumbing. The error alert, camera sheet, photos picker, and the
            // .onChange observer that reacts to the user picking an image — all anchored
            // on the NavigationStack rather than inside the toolbar so the toolbar items
            // don't need to host them.
            .alert("OCR Import Failed", isPresented: ocrImportErrorPresented) {
                Button("OK", role: .cancel) {
                    ocrImportErrorMessage = ""
                }
            } message: {
                Text(ocrImportErrorMessage)
            }
            .sheet(isPresented: $isShowingCameraPicker) {
                CameraImagePicker(onImagePicked: { imageData in
                    Task {
                        await importTextFromOCRImageData(imageData)
                    }
                })
            }
            .sheet(isPresented: $isShowingURLImportSheet) {
                URLImportSheet { note in
                    onOCRImportedNote?(note)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .photosPicker(
                isPresented: $isShowingPhotoLibraryPicker,
                selection: $selectedOCRImageItem,
                matching: .images,
                preferredItemEncoding: .automatic
            )
            .onChange(of: selectedOCRImageItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await importTextFromSelectedOCRImage(newItem)
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
            hasSubtitles: NotesAudioStore.shared.hasCues(for: attachmentID)
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

    // Describes a pending note deletion for the unified confirmation dialog.
    private struct PendingNoteDeletion {
        let noteIDs: Set<UUID>
        let title: String?
    }

    // Binds delete-dialog presentation directly to the pending deletion.
    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if isPresented == false {
                    pendingDeletion = nil
                }
            }
        )
    }

    // Per-row delete-confirmation binding: true only when exactly THIS note is the pending deletion.
    // The confirmationDialog is attached to each row, so iOS anchors its popover arrow to the row
    // that triggered the delete (a top-level dialog can't track the source row → arrow points wrong).
    private func rowDeletePresented(_ note: Note) -> Binding<Bool> {
        Binding(
            get: { pendingDeletion?.noteIDs == [note.id] },
            set: { if $0 == false { pendingDeletion = nil } }
        )
    }

    // Multi-note (toolbar) deletes have no single source row, so they keep a top-level dialog.
    private var bulkDeleteDialogPresented: Binding<Bool> {
        Binding(
            get: { (pendingDeletion?.noteIDs.count ?? 0) > 1 },
            set: { if $0 == false { pendingDeletion = nil } }
        )
    }

    // Title for the delete dialog: names a single note, or counts multiple.
    private var deleteDialogTitle: String {
        guard let pendingDeletion else { return "Delete Note?" }
        if let title = pendingDeletion.title { return "Delete “\(title)”?" }
        return "Delete \(pendingDeletion.noteIDs.count) Notes?"
    }

    // "" for one pending note, "s" for several — pluralizes the dialog copy.
    private var pendingNoteCountSuffix: String {
        (pendingDeletion?.noteIDs.count ?? 1) == 1 ? "" : "s"
    }

    // Explains that note deletion never removes independent saved vocabulary.
    private var deleteDialogMessage: String {
        "This permanently removes the note\(pendingNoteCountSuffix) and its attachments. Saved words are kept."
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
            pendingDeletion = PendingNoteDeletion(noteIDs: [note.id], title: resolvedTitle(for: note))
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

    // Deletes the pending notes, detaches saved-word provenance, and clears the active selection.
    private func performDelete() {
        guard let pendingDeletion else { return }
        let noteIDs = pendingDeletion.noteIDs

        wordsStore.detachNoteReferences(noteIDs: noteIDs)
        store.deleteNotes(ids: noteIDs)
        selectedNoteIDs.subtract(noteIDs)
        onUpdateSelectedNote?(nil)
        self.pendingDeletion = nil
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
