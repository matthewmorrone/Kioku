import SwiftUI
import Combine

@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet { save() }
    }

    private let storageKey = "kioku.notes.v1"
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
        notes[index].readingOverrides = nil
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
            segments: sourceNote.segments,
            readingOverrides: sourceNote.readingOverrides
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
    func upsertNote(id: UUID?, title: String, content: String, segments: [SegmentRange]?, readingOverrides: [Int: String]? = nil) -> UUID {
        let now = Date()
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].title = title
            notes[index].content = content
            notes[index].segments = segments
            notes[index].readingOverrides = readingOverrides
            notes[index].modifiedAt = now
            return id
        }

        let newNote = Note(title: title, content: content, segments: segments, createdAt: now, modifiedAt: now, readingOverrides: readingOverrides)
        notes.insert(newNote, at: 0)
        return newNote.id
    }

    // Persists a read-screen edit by upserting into the in-memory store and writing to disk immediately.
    // Uses upsertNote so writes are synchronous and there is no window where data can be lost on process kill.
    @discardableResult
    func scheduleReadEditorPersist(id: UUID?, title: String, content: String, segments: [SegmentRange]?, readingOverrides: [Int: String]? = nil) -> UUID {
        upsertNote(id: id, title: title, content: content, segments: segments, readingOverrides: readingOverrides)
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
        return [SegmentRange(start: 0, end: utf16Length)]
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
