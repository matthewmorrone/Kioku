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
    // Supplies JLPT levels for the Difficulty sort. Optional because the dictionary is built
    // asynchronously at launch; until it lands, Difficulty simply has nothing to rank by.
    var dictionaryStore: DictionaryStore? = nil

    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var wordsStore: WordsStore
    @EnvironmentObject private var savedKanjiStore: SavedKanjiStore
    @EnvironmentObject private var songBreakdownStore: SongBreakdownStore
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
    // Sort selection persists across launches. Stored as the raw field string plus a direction
    // flag rather than one combined case so adding a field later doesn't invalidate saved values.
    @AppStorage("notes.sortField") private var sortFieldRaw = NotesSortField.manual.rawValue
    @AppStorage("notes.sortAscending") private var sortAscending = NotesSortField.manual.defaultAscending

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
            // Displays the selectable/reorderable list of notes. Correction-queue
            // progress is shown by CorrectionProgressOverlay (mounted globally in
            // ContentView so it follows the user between tabs), not inline here.
            List(selection: $selectedNoteIDs) {
                ForEach(displayedNotes) { note in
                    noteRow(for: note)
                }
                // Reordering is only meaningful against the stored order; under a derived sort
                // there is no stable slot to drop into, so the handles are withheld instead of
                // silently rewriting an order the sort would immediately override.
                .onMove(perform: moveHandler)
                .onDelete { offsets in
                    // Route swipe-to-delete through the same confirmation so the associated-word
                    // offer applies here too (it previously deleted immediately). Deferred
                    // assignment matches the context-menu path so swipe dismissal doesn't
                    // collide with the dialog presentation either.
                    let notes = offsets.compactMap { displayedNotes.indices.contains($0) ? displayedNotes[$0] : nil }
                    queuePendingDeletion(PendingNoteDeletion(
                        noteIDs: Set(notes.map(\.id)),
                        title: notes.count == 1 ? resolvedTitle(for: notes[0]) : nil
                    ))
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
            // Single source-of-truth confirmation for both single-note and multi-note deletes.
            // Uses .alert (not .confirmationDialog) because on iOS 27 the per-row
            // confirmationDialog pattern dismissed itself one frame after presenting, and a
            // List-level confirmationDialog took a stale popover anchor (the original bug
            // commit 5ee33b4 was trying to dodge). Alerts are centered modal cards with no
            // anchor at all, so neither failure mode applies — at the cost of the
            // action-sheet look. `presenting:` keeps the title, buttons, and action bound to
            // the pending deletion so the content can't go stale either.
            .alert(
                deleteDialogTitle,
                isPresented: deletePresented,
                presenting: pendingDeletion
            ) { deletion in
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
                Button("Delete Note\(countSuffix(for: deletion))", role: .destructive) {
                    performDelete(deletion, alsoRemoveOrphanedWords: false)
                }
                // Only offered when something would actually be orphaned — a note with no
                // note-only vocabulary just gets the one Delete button above.
                let orphanCount = orphanedWordCount(for: deletion)
                if orphanCount > 0 {
                    Button("Delete Note\(countSuffix(for: deletion)) and \(orphanCount) Word\(orphanCount == 1 ? "" : "s")", role: .destructive) {
                        performDelete(deletion, alsoRemoveOrphanedWords: true)
                    }
                }
            } message: { deletion in
                Text(deleteDialogMessage(for: deletion))
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
            .washiBackground()
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
                    sortMenu

                    // Shows bulk-delete action while edit mode is active.
                    if editMode == .active {
                        Button {
                            queuePendingDeletion(PendingNoteDeletion(noteIDs: selectedNoteIDs, title: nil))
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

    // The currently selected sort field, defaulting to manual if a stored raw value is
    // no longer recognized (e.g. after a downgrade).
    private var sortField: NotesSortField {
        NotesSortField(rawValue: sortFieldRaw) ?? .manual
    }

    // The list as shown: the store's order under `manual`, otherwise a derived ordering. The
    // store array itself is never re-written by sorting, so the manual order always survives.
    // Renders a single note row with title, content preview, and attachment indicators.
    // Extracted from `body` to keep the list's expression small enough for the type checker.
    @ViewBuilder
    private func noteRow(for note: Note) -> some View {
        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trimmedTitle.isEmpty ? "" : note.title)
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

    // Written as an early return rather than a `condition ? store.moveNotes : nil` ternary:
    // mixing a method reference with nil in one ternary made the type checker give up
    // ("failed to produce diagnostic for expression"), whether it sat here or in `body`.
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard sortField == .manual else { return nil }
        return { source, destination in
            store.moveNotes(from: source, to: destination)
        }
    }

    // Same reason: the Picker's binding is built here rather than inline in `sortMenu`.
    private var sortFieldBinding: Binding<NotesSortField> {
        Binding(
            get: { self.sortField },
            set: { newField in
                guard newField != self.sortField else { return }
                self.sortFieldRaw = newField.rawValue
                self.sortAscending = newField.defaultAscending
            }
        )
    }

    private var displayedNotes: [Note] {
        // Snapshot the metrics once — the closure is called on every comparison, and
        // metricsByNoteID rebuilds the whole table each time it is read.
        let metrics = metricsByNoteID
        return NotesSorting.sorted(
            store.notes,
            field: sortField,
            ascending: sortAscending,
            metrics: { metrics[$0.id] ?? NoteSortMetrics() }
        )
    }

    // Learning metrics for every note in one pass over the saved words, rather than re-scanning
    // the word list once per note inside the comparator (which would make the sort O(notes ×
    // words × log notes)). Only computed for the two fields that need it.
    private var metricsByNoteID: [UUID: NoteSortMetrics] {
        guard sortField == .wordsToLearn || sortField == .difficulty else { return [:] }

        var unlearned: [UUID: Int] = [:]
        var levelTotals: [UUID: (sum: Int, count: Int)] = [:]

        for word in wordsStore.words {
            let id = word.canonicalEntryID
            let stage = wordsStore.masteryStage(for: id)
            let isUnlearned = stage != .learned && stage != .mastered
            // jlptLevel is N-number (N5 = 5, easiest); invert so a bigger score means harder.
            let difficulty = dictionaryStore?.jlptLevel(for: id).map { 6 - $0 }

            for noteID in Set(word.sourceNoteIDs) {
                if isUnlearned { unlearned[noteID, default: 0] += 1 }
                if let difficulty {
                    let running: (sum: Int, count: Int) = levelTotals[noteID] ?? (sum: 0, count: 0)
                    levelTotals[noteID] = (sum: running.sum + difficulty, count: running.count + 1)
                }
            }
        }

        var result: [UUID: NoteSortMetrics] = [:]
        for note in store.notes {
            let totals = levelTotals[note.id]
            result[note.id] = NoteSortMetrics(
                wordsToLearn: unlearned[note.id] ?? 0,
                difficulty: totals.map { Double($0.sum) / Double($0.count) }
            )
        }
        return result
    }

    // Field picker plus a direction toggle. Direction is hidden for `manual`, which has only
    // the one order; picking a new field resets the direction to that field's natural default
    // (A→Z for names, newest/longest/hardest first for the rest).
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: sortFieldBinding) {
                ForEach(NotesSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }

            if sortField != .manual {
                Divider()
                Picker("Order", selection: $sortAscending) {
                    Text(sortField.directionLabel(ascending: false)).tag(false)
                    Text(sortField.directionLabel(ascending: true)).tag(true)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
        }
        .accessibilityLabel("Sort Notes")
    }

    // Shows whether a note currently has stored audio/subtitle files attached and/or a
    // generated breakdown.
    @ViewBuilder
    private func noteAttachmentIndicators(for note: Note) -> some View {
        let attachmentState = attachmentState(for: note)
        let hasBreakdown = songBreakdownStore.breakdown(forNoteID: note.id) != nil

        if attachmentState.hasAudio || attachmentState.hasSubtitles || hasBreakdown {
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

                if hasBreakdown {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Has a generated breakdown")
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

    // Drives the single List-level delete alert. True whenever any deletion is pending
    // (single OR multi), so one alert instance handles both. Clearing the binding
    // (Cancel button, system dismiss) nils the pending deletion so the alert re-presents
    // cleanly next time.
    private var deletePresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if isPresented == false {
                    pendingDeletion = nil
                }
            }
        )
    }

    // Defers assigning pendingDeletion to the next runloop tick. Setting it synchronously
    // from a context-menu or swipe action animates poorly: the menu/swipe is still
    // dismissing, the alert wants to mount, and on iOS 27 the two phases interleave in a
    // way that occasionally drops the alert one frame after present. One main-thread hop
    // lets the source affordance finish dismissing before the alert binding flips.
    private func queuePendingDeletion(_ deletion: PendingNoteDeletion) {
        DispatchQueue.main.async {
            self.pendingDeletion = deletion
        }
    }

    // Title for the delete dialog: names a single note, or counts multiple.
    private var deleteDialogTitle: String {
        guard let pendingDeletion else { return "Delete Note?" }
        if let title = pendingDeletion.title { return "Delete “\(title)”?" }
        return "Delete \(pendingDeletion.noteIDs.count) Notes?"
    }

    // "" for one pending note, "s" for several — pluralizes the dialog copy.
    private func countSuffix(for deletion: PendingNoteDeletion) -> String {
        deletion.noteIDs.count == 1 ? "" : "s"
    }

    // Explains what note deletion does to attachments and, when relevant, to vocabulary that
    // has nothing else backing it once this note is gone.
    private func deleteDialogMessage(for deletion: PendingNoteDeletion) -> String {
        let base = "This permanently removes the note\(countSuffix(for: deletion)) and its attachments."
        let orphanCount = orphanedWordCount(for: deletion)
        guard orphanCount > 0 else {
            return base + " Saved words are kept."
        }
        let notePhrase = deletion.noteIDs.count == 1 ? "this note" : "these notes"
        return base + " \(orphanCount) saved word\(orphanCount == 1 ? "" : "s") only attributed to \(notePhrase) would otherwise be orphaned — choose whether to keep or delete \(orphanCount == 1 ? "it" : "them") too."
    }

    // Saved words attributed ONLY to the note(s) about to be deleted — every other attribution
    // has already been ruled out, so once this note is gone they'd have nothing left backing
    // them. Excludes words with no note attribution at all (global saves), which aren't
    // affected by this deletion either way. Must run BEFORE detachNoteReferences, which clears
    // sourceNoteIDs and would make this test trivially empty afterward.
    private func orphanedWords(for deletion: PendingNoteDeletion) -> [SavedWord] {
        wordsStore.words.filter {
            $0.sourceNoteIDs.isEmpty == false && Set($0.sourceNoteIDs).subtracting(deletion.noteIDs).isEmpty
        }
    }

    // Saved kanji counterpart to orphanedWords(for:), same rationale.
    private func orphanedKanji(for deletion: PendingNoteDeletion) -> [SavedKanji] {
        savedKanjiStore.kanji.filter {
            $0.sourceNoteIDs.isEmpty == false && Set($0.sourceNoteIDs).subtracting(deletion.noteIDs).isEmpty
        }
    }

    // Combined count driving the dialog's copy and its conditional second delete button.
    private func orphanedWordCount(for deletion: PendingNoteDeletion) -> Int {
        orphanedWords(for: deletion).count + orphanedKanji(for: deletion).count
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
            queuePendingDeletion(PendingNoteDeletion(noteIDs: [note.id], title: resolvedTitle(for: note)))
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
    // Takes the deletion the dialog was presenting so we act on exactly that note set, never a
    // value that may have been replaced between presentation and confirmation. When
    // alsoRemoveOrphanedWords is true, words/kanji attributed only to these notes are hard-
    // removed instead of just detached — captured before detachNoteReferences runs, since that
    // clears sourceNoteIDs and would make the "only this note" test always empty afterward.
    private func performDelete(_ deletion: PendingNoteDeletion, alsoRemoveOrphanedWords: Bool) {
        let noteIDs = deletion.noteIDs
        let wordIDsToRemove = alsoRemoveOrphanedWords ? Set(orphanedWords(for: deletion).map(\.canonicalEntryID)) : []
        let kanjiLiteralsToRemove = alsoRemoveOrphanedWords ? orphanedKanji(for: deletion).map(\.literal) : []

        wordsStore.detachNoteReferences(noteIDs: noteIDs)
        savedKanjiStore.detachNoteReferences(noteIDs: noteIDs)
        if wordIDsToRemove.isEmpty == false {
            wordsStore.remove(ids: wordIDsToRemove)
        }
        for literal in kanjiLiteralsToRemove {
            savedKanjiStore.remove(literal: literal)
        }
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
