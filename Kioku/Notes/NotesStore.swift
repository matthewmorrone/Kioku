import SwiftUI
import Combine

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet {
            guard suppressSave == false else { return }
            save()
        }
    }

    private let storageKey = "kioku.notes.v1"
    private var runtimeSegmentationByNoteID: [UUID: NotesRuntimeSegmentationSnapshot] = [:]
    private var saveTask: Task<Void, Never>?
    private var suppressSave = false

    // Loads persisted notes so the in-memory store starts from disk state.
    init() {
        let key = storageKey
        notes = StartupTimer.measure("NotesStore.init") {
            NotesStore.readNotes(for: key)
        }
    }

    // Reloads notes from storage to reflect external updates.
    func reload() {
        saveTask?.cancel()
        suppressSave = true
        notes = NotesStore.readNotes(for: storageKey)
        suppressSave = false
    }

    // Inserts a new empty note at the top of the list.
    func addNote() {
        notes.insert(Note(), at: 0)
    }

    // Inserts a provided note at the top of the list and persists it with the current collection.
    func addNote(_ note: Note) {
        notes.insert(note, at: 0)
    }

    // Reorders notes using list move semantics.
    func moveNotes(from source: IndexSet, to destination: Int) {
        notes.move(fromOffsets: source, toOffset: destination)
    }

    // Deletes notes at the provided list offsets.
    func deleteNotes(at offsets: IndexSet) {
        notes.remove(atOffsets: offsets)
    }

    // Deletes notes whose identifiers are currently selected.
    func deleteNotes(ids: Set<UUID>) {
        notes.removeAll { ids.contains($0.id) }
    }

    // Deletes one note by identifier and returns the removed note if it existed.
    @discardableResult
    func deleteNote(id: UUID) -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        runtimeSegmentationByNoteID[id] = nil
        return notes.remove(at: index)
    }

    // Renames one note while preserving its content and segment metadata.
    func renameNote(id: UUID, title: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        notes[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].modifiedAt = Date()
    }

    // Clears stored segmentation and reading overrides so the segmenter recomputes from scratch on next load.
    func resetNote(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        notes[index].segments = nil
        notes[index].modifiedAt = Date()
    }

    // Duplicates one note into a new identifier and inserts the copy at the top of the list.
    func duplicateNote(id: UUID) -> Note? {
        guard let sourceNote = note(withID: id) else {
            return nil
        }

        let duplicatedNote = Note(
            title: sourceNote.title,
            content: sourceNote.content,
            segments: sourceNote.segments
        )
        notes.insert(duplicatedNote, at: 0)
        return duplicatedNote
    }

    // Returns the note for a known identifier from the in-memory store.
    func note(withID id: UUID) -> Note? {
        notes.first(where: { $0.id == id })
    }

    // Records the latest runtime segmentation for a note so export can reuse live read-view state.
    func recordRuntimeSegmentation(noteID: UUID, content: String, segments: [SegmentRange]) {
        runtimeSegmentationByNoteID[noteID] = NotesRuntimeSegmentationSnapshot(content: content, segments: segments)
    }

    // Packages the current notes array into an export document using existing runtime or persisted segmentation ranges.
    func makeTransferDocument() -> NotesTransferDocument {
        let exportNotes = notes.map { note in
            var noteForExport = note
            noteForExport.segments = exportSegmentRanges(for: note)
            return noteForExport
        }
        return NotesTransferDocument(notes: exportNotes)
    }

    // Returns the current notes collection as export-ready values with live segmentation snapshots applied.
    func exportNotes() -> [Note] {
        makeTransferDocument().payload.notes
    }

    // Imports notes using the selected merge strategy and persists the resulting collection.
    func importTransferDocument(_ document: NotesTransferDocument, mode: NotesImportMode) {
        let importedNotes = document.payload.notes
        switch mode {
        case .replaceAll:
            notes = importedNotes
        case .overwriteByID:
            notes = mergedNotesOverwritingByID(importedNotes)
        case .overwriteByTitle:
            notes = mergedNotesOverwritingByTitle(importedNotes)
        case .append:
            notes += importedNotes
        }
    }

    // Replaces the entire notes collection with one validated snapshot.
    func replaceAll(with notes: [Note]) {
        runtimeSegmentationByNoteID = [:]
        self.notes = notes
    }

    // Merges imported notes by replacing existing entries with matching identifiers.
    private func mergedNotesOverwritingByID(_ importedNotes: [Note]) -> [Note] {
        var mergedNotes = notes
        var existingIndexByID: [UUID: Int] = [:]

        for (index, note) in mergedNotes.enumerated() {
            existingIndexByID[note.id] = index
        }

        for importedNote in importedNotes {
            if let existingIndex = existingIndexByID[importedNote.id] {
                mergedNotes[existingIndex] = importedNote
            } else {
                existingIndexByID[importedNote.id] = mergedNotes.count
                mergedNotes.append(importedNote)
            }
        }

        return mergedNotes
    }

    // Merges imported notes by replacing existing entries whose trimmed title matches.
    private func mergedNotesOverwritingByTitle(_ importedNotes: [Note]) -> [Note] {
        var mergedNotes = notes
        var existingIndexByNormalizedTitle: [String: Int] = [:]

        for (index, note) in mergedNotes.enumerated() {
            let normalizedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedTitle.isEmpty == false, existingIndexByNormalizedTitle[normalizedTitle] == nil {
                existingIndexByNormalizedTitle[normalizedTitle] = index
            }
        }

        for importedNote in importedNotes {
            let normalizedImportedTitle = importedNote.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedImportedTitle.isEmpty == false,
               let existingIndex = existingIndexByNormalizedTitle[normalizedImportedTitle] {
                let existingNote = mergedNotes[existingIndex]
                var updatedNote = importedNote
                updatedNote.id = existingNote.id
                updatedNote.createdAt = existingNote.createdAt
                mergedNotes[existingIndex] = updatedNote
            } else {
                mergedNotes.append(importedNote)
                if normalizedImportedTitle.isEmpty == false {
                    existingIndexByNormalizedTitle[normalizedImportedTitle] = mergedNotes.count - 1
                }
            }
        }

        return mergedNotes
    }

    // Inserts or updates one note in memory so editing does not re-read the full store.
    func upsertNote(id: UUID?, title: String, content: String, segments: [SegmentRange]?) -> UUID {
        let now = Date()
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].title = title
            notes[index].content = content
            notes[index].segments = segments
            notes[index].modifiedAt = now
            return id
        }

        let newNote = Note(title: title, content: content, segments: segments, createdAt: now, modifiedAt: now)
        notes.insert(newNote, at: 0)
        return newNote.id
    }

    // Updates the audio attachment binding for one note without disturbing text or segmentation.
    func updateAudioAttachment(id: UUID, attachmentID: UUID?) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        notes[index].audioAttachmentID = attachmentID
        notes[index].modifiedAt = Date()
    }

    // Persists a read-screen edit by upserting into the in-memory store and writing to disk immediately.
    // Uses upsertNote so writes are coalesced in memory and can be flushed explicitly when needed.
    @discardableResult
    func scheduleReadEditorPersist(id: UUID?, title: String, content: String, segments: [SegmentRange]?) -> UUID {
        upsertNote(id: id, title: title, content: content, segments: segments)
    }

    // Forces the latest in-memory snapshot to disk, used when the app is backgrounding or a screen disappears.
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        Self.persist(notes: notes, for: storageKey)
    }

    // Produces export segment ranges from existing runtime or persisted state without recomputing segmentation.
    private func exportSegmentRanges(for note: Note) -> [SegmentRange] {
        let utf16Length = note.content.utf16.count
        guard utf16Length > 0 else {
            return []
        }

        if let runtimeSnapshot = runtimeSegmentationByNoteID[note.id],
           runtimeSnapshot.content == note.content,
           runtimeSnapshot.segments.isEmpty == false {
            return runtimeSnapshot.segments
        }

        if let segments = note.segments, segments.isEmpty == false {
            return segments
        }

        // Guarantees at least one export segment for non-empty content even when no manual segmentation exists.
        return [SegmentRange(start: 0, end: utf16Length, surface: note.content)]
    }

    // Persists the current notes array into user defaults immediately.
    private func save() {
        let snapshot = notes
        let key = storageKey
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            guard Task.isCancelled == false else { return }
            Self.persist(notes: snapshot, for: key)
        }
    }

    // Encodes and persists a concrete note snapshot without touching main-actor state.
    private nonisolated static func persist(notes: [Note], for key: String) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // Reads and decodes notes for the given storage key.
    private static func readNotes(for key: String) -> [Note] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else {
            return []
        }

        return decoded
    }
}
