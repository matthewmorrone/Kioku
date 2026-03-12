import SwiftUI
import Combine

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet {
            clearPendingReadEditorPersistState()
            save()
        }
    }

    private let storageKey = "kioku.notes.v1"
    private let persistenceQueue = DispatchQueue(label: "Kioku.NotesStore.persistence", qos: .utility)
    private var pendingReadEditorPersistWorkItem: DispatchWorkItem?
    private var pendingReadEditorPersistNote: Note?
    private var runtimeSegmentationByNoteID: [UUID: NotesRuntimeSegmentationSnapshot] = [:]

    // Loads persisted notes so the in-memory store starts from disk state.
    init() {
        notes = NotesStore.readNotes(for: storageKey)
    }

    // Reloads notes from storage to reflect external updates.
    func reload() {
        notes = NotesStore.readNotes(for: storageKey)
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

    // Renames one note while preserving its content and token metadata.
    func renameNote(id: UUID, title: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        notes[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].modifiedAt = Date()
    }

    // Resets one note back to a blank title, blank content, and no stored token overrides.
    func resetNote(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        notes[index].title = ""
        notes[index].content = ""
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

    // Returns the latest in-memory note for a known identifier.
    func note(withID id: UUID) -> Note? {
        notes.first(where: { $0.id == id })
    }

    // Records the latest runtime segmentation for a note so export can reuse live read-view state.
    func recordRuntimeSegmentation(noteID: UUID, content: String, segments: [SegmentRange]) {
        runtimeSegmentationByNoteID[noteID] = NotesRuntimeSegmentationSnapshot(content: content, segments: segments)
    }

    // Packages the current notes array into an export document using existing runtime or persisted segmentation ranges.
    func makeTransferDocument() -> NotesTransferDocument {
        let flushedNotes = flushPendingReadEditorPersistIfNeeded()
        let baseNotes = flushedNotes ?? NotesStore.readNotes(for: storageKey)
        let exportNotes = baseNotes.map { note in
            var noteForExport = note
            noteForExport.segments = exportSegmentRanges(for: note)
            return noteForExport
        }
        return NotesTransferDocument(notes: exportNotes)
    }

    // Replaces the current notes collection with imported data and persists it.
    func importTransferDocument(_ document: NotesTransferDocument) {
        clearPendingReadEditorPersistState()
        notes = document.payload.notes
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

    // Schedules a read-screen edit to persist directly to storage without publishing every intermediate change.
    func scheduleReadEditorPersist(id: UUID?, title: String, content: String, segments: [SegmentRange]?) -> UUID {
        let resolvedID = id ?? UUID()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let existingCreatedAt = notes.first(where: { $0.id == resolvedID })?.createdAt ?? now
        let noteToPersist = Note(
            id: resolvedID,
            title: trimmedTitle,
            content: content,
            segments: segments,
            createdAt: existingCreatedAt,
            modifiedAt: now
        )

        pendingReadEditorPersistWorkItem?.cancel()
        pendingReadEditorPersistNote = noteToPersist

        let storageKey = storageKey
        let workItem = DispatchWorkItem {
            var notes = Self.readNotes(for: storageKey)
            if let index = notes.firstIndex(where: { $0.id == resolvedID }) {
                notes[index] = noteToPersist
            } else {
                notes.insert(noteToPersist, at: 0)
            }

            guard let encoded = try? JSONEncoder().encode(notes) else { return }
            UserDefaults.standard.set(encoded, forKey: storageKey)

            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pendingReadEditorPersistNote == noteToPersist {
                    self.clearPendingReadEditorPersistState()
                }
            }
        }

        pendingReadEditorPersistWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        return resolvedID
    }

    // Flushes any pending read-editor write so exports include the latest debounced note content and token ranges.
    private func flushPendingReadEditorPersistIfNeeded() -> [Note]? {
        guard let noteToPersist = pendingReadEditorPersistNote else {
            return nil
        }

        clearPendingReadEditorPersistState()

        var latestNotes = Self.readNotes(for: storageKey)
        if let index = latestNotes.firstIndex(where: { $0.id == noteToPersist.id }) {
            latestNotes[index] = noteToPersist
        } else {
            latestNotes.insert(noteToPersist, at: 0)
        }

        guard let encoded = try? JSONEncoder().encode(latestNotes) else {
            return latestNotes
        }

        UserDefaults.standard.set(encoded, forKey: storageKey)
        return latestNotes
    }

    // Clears pending debounced read-editor persistence bookkeeping.
    private func clearPendingReadEditorPersistState() {
        pendingReadEditorPersistWorkItem?.cancel()
        pendingReadEditorPersistWorkItem = nil
        pendingReadEditorPersistNote = nil
    }

    // Produces export token ranges from existing runtime or persisted state without recomputing segmentation.
    private func exportSegmentRanges(for note: Note) -> [SegmentRange] {
        if let runtimeSnapshot = runtimeSegmentationByNoteID[note.id],
           runtimeSnapshot.content == note.content,
           runtimeSnapshot.segments.isEmpty == false {
            return runtimeSnapshot.segments
        }

        if let segments = note.segments, segments.isEmpty == false {
            return segments
        }

        guard note.content.isEmpty == false else {
            return []
        }

        return []
    }

    // Persists the current notes array into user defaults immediately.
    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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
