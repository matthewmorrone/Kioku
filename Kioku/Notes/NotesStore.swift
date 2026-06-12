import SwiftUI
import Combine

// Persists notes as one JSON file per note under Application Support/Notes/ with an
// _index.json file recording display order. Replaces the prior single-UserDefaults-blob
// storage so:
//   - One corrupt note doesn't take the whole collection down (per-note decode is isolated)
//   - A transient read failure on launch can't be silently overwritten by a stale empty
//     in-memory state on the next save (see `flushPendingSave` defense)
//   - The collection survives any kind of process crash / sudden quit; only an explicit
//     uninstall or `replaceAll(with: [])` can clear it
//
// First launch after upgrade migrates from the legacy `kioku.notes.v1` UserDefaults key
// (read-only) and leaves it untouched on disk for downgrade safety. Files are the
// authoritative store from that point on.
@MainActor
final class NotesStore: ObservableObject {
    @Published var notes: [Note] {
        didSet {
            guard suppressSave == false else { return }
            save()
        }
    }
    @Published private(set) var persistenceError: String?

    // Legacy UserDefaults key. Read only on first migration; never written from this class
    // again so that downgrading to an older build still sees its original snapshot.
    private let legacyStorageKey = "kioku.notes.v1"

    // Per-note JSON files live here; `_index.json` records ordering.
    private let directoryURL: URL
    private let indexURL: URL
    private let fileManager: FileManager
    private let attachmentStore: any NotesAttachmentDeleting
    private let fileWriter: any NotesFileWriting

    // Mirrors what is currently on disk so save() can diff and only write changed files.
    // Without this every keystroke would rewrite every note file.
    private var diskSnapshotByID: [UUID: Note] = [:]

    private var runtimeSegmentationByNoteID: [UUID: NotesRuntimeSegmentationSnapshot] = [:]
    private var saveTask: Task<Void, Never>?
    private var suppressSave = false
    private var allowEmptySave = false
    private var pendingAttachmentDeletions: Set<UUID> = []

    // Loads persisted notes so the in-memory store starts from disk state. Tries the
    // file-based layout first; if none, migrates from the legacy UserDefaults blob and
    // writes the resulting notes back as files. Either way `diskSnapshotByID` is
    // populated so subsequent writes can be diff-based.
    init(
        fileManager: FileManager = .default,
        attachmentStore: any NotesAttachmentDeleting = NotesAudioStore.shared,
        fileWriter: any NotesFileWriting = NotesFileWriter()
    ) {
        self.fileManager = fileManager
        self.attachmentStore = attachmentStore
        self.fileWriter = fileWriter
        let base = NotesStore.applicationSupportDirectory(fileManager: fileManager)
        self.directoryURL = base.appendingPathComponent("Notes", isDirectory: true)
        self.indexURL = self.directoryURL.appendingPathComponent("_index.json", isDirectory: false)
        NotesStore.ensureDirectoryExists(at: directoryURL, fileManager: fileManager)

        let fromFiles = NotesStore.readNotesFromFiles(
            directory: directoryURL,
            indexURL: indexURL,
            fileManager: fileManager
        )

        if fromFiles.isEmpty == false {
            notes = fromFiles
            diskSnapshotByID = Dictionary(uniqueKeysWithValues: fromFiles.map { ($0.id, $0) })
            return
        }

        // No files yet: try a one-time migration from the legacy UserDefaults blob.
        let fromLegacy = NotesStore.readNotesFromLegacyUserDefaults(key: legacyStorageKey)
        if fromLegacy.isEmpty == false {
            notes = fromLegacy
            do {
                try NotesStore.writeFiles(
                    notes: fromLegacy,
                    previousSnapshot: [:],
                    directory: directoryURL,
                    indexURL: indexURL,
                    fileManager: fileManager,
                    fileWriter: fileWriter
                )
                diskSnapshotByID = Dictionary(uniqueKeysWithValues: fromLegacy.map { ($0.id, $0) })
            } catch {
                persistenceError = Self.persistenceMessage(for: error)
            }
        } else {
            notes = []
        }
    }

    // Reloads notes from storage to reflect external updates. Flushes any pending in-memory
    // write first so an in-flight save doesn't get cancelled and replaced by a stale disk
    // read. Safe to call repeatedly; will not destructively overwrite a populated on-disk
    // state with an empty in-memory snapshot (see flushPendingSave).
    func reload() {
        flushPendingSave()
        suppressSave = true
        let fromFiles = NotesStore.readNotesFromFiles(
            directory: directoryURL,
            indexURL: indexURL,
            fileManager: fileManager
        )
        notes = fromFiles
        diskSnapshotByID = Dictionary(uniqueKeysWithValues: fromFiles.map { ($0.id, $0) })
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
        let ids = Set(offsets.compactMap { index in
            notes.indices.contains(index) ? notes[index].id : nil
        })
        deleteNotes(ids: ids)
    }

    // Deletes notes whose identifiers are currently selected.
    func deleteNotes(ids: Set<UUID>) {
        guard ids.isEmpty == false else { return }
        allowEmptySave = true
        replaceNotesRemovingAttachments(with: notes.filter { ids.contains($0.id) == false })
        allowEmptySave = false
    }

    // Deletes one note by identifier and returns the removed note if it existed.
    @discardableResult
    func deleteNote(id: UUID) -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        let removed = notes[index]
        deleteNotes(ids: [id])
        return removed
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

    // Drops the in-memory runtime segmentation snapshot for a note. Used by Reset Segmentation so
    // a stale snapshot containing the old (buggy) per-segment furigana can't be served back by
    // export or by any consumer that reads through `runtimeSegmentationByNoteID` before the next
    // segmenter pass has installed a fresh one.
    func clearRuntimeSegmentation(noteID: UUID) {
        runtimeSegmentationByNoteID[noteID] = nil
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
    //
    // The empty-replacement path bypasses save()'s defensive guard: it deletes
    // the on-disk files for every note that was present, then resets the
    // snapshot. Without this, replaceAll(with: []) would set notes to [] and
    // the didSet save() would see "in-memory empty + disk populated" and
    // refuse the write — protecting against the "in-memory accidentally went
    // empty" failure pattern but also blocking the one intentional clear-all
    // call site.
    func replaceAll(with notes: [Note]) {
        runtimeSegmentationByNoteID = [:]
        let removedAttachmentIDs = attachmentIDsRemoved(byReplacingWith: notes)
        pendingAttachmentDeletions.formUnion(removedAttachmentIDs)
        allowEmptySave = true
        self.notes = notes
        allowEmptySave = false
    }

    // Replaces notes and removes attachment files no surviving note references.
    private func replaceNotesRemovingAttachments(with replacement: [Note]) {
        let removedAttachmentIDs = attachmentIDsRemoved(byReplacingWith: replacement)
        pendingAttachmentDeletions.formUnion(removedAttachmentIDs)
        runtimeSegmentationByNoteID = runtimeSegmentationByNoteID.filter { snapshot in
            replacement.contains { $0.id == snapshot.key }
        }
        notes = replacement
    }

    // Computes attachment identifiers present only in the current collection.
    private func attachmentIDsRemoved(byReplacingWith replacement: [Note]) -> Set<UUID> {
        let current = Set(notes.compactMap(\.audioAttachmentID))
        let surviving = Set(replacement.compactMap(\.audioAttachmentID))
        return current.subtracting(surviving)
    }

    // Deletes attachment files after the note mutation has been persisted.
    private func deleteAttachments(_ attachmentIDs: Set<UUID>) {
        for attachmentID in attachmentIDs {
            attachmentStore.deleteAttachment(attachmentID)
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
    // `segmentsAreUserEdited` uses preserve-on-nil semantics: pass an explicit Bool to set the
    // marker (read editor / import), or leave it nil to keep the existing value on update (and
    // default to false on insert). This stops callers that don't care about the marker — bridge
    // routes, transcription — from clobbering a note's user-edited status.
    func upsertNote(id: UUID?, title: String, content: String, segments: [SegmentRange]?, segmentsAreUserEdited: Bool? = nil) -> UUID {
        let now = Date()
        if let id, let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].title = title
            notes[index].content = content
            notes[index].segments = segments
            if let segmentsAreUserEdited {
                notes[index].segmentsAreUserEdited = segmentsAreUserEdited
            }
            notes[index].modifiedAt = now
            return id
        }

        let newNote = Note(title: title, content: content, segments: segments, segmentsAreUserEdited: segmentsAreUserEdited ?? false, createdAt: now, modifiedAt: now)
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
    func scheduleReadEditorPersist(id: UUID?, title: String, content: String, segments: [SegmentRange]?, segmentsAreUserEdited: Bool? = nil) -> UUID {
        upsertNote(id: id, title: title, content: content, segments: segments, segmentsAreUserEdited: segmentsAreUserEdited)
    }

    // Cancels any pending detached save and synchronously flushes whatever's in memory
    // — *unless* doing so would replace a populated on-disk state with an empty in-memory
    // one. That defensive guard is the core fix for the recurring "notes were nuked after
    // a transient read failure" pattern: if init's decode produced an empty array but
    // there ARE files on disk, we refuse to overwrite them.
    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil

        if notes.isEmpty, diskSnapshotByID.isEmpty == false, allowEmptySave == false,
           pendingAttachmentDeletions.isEmpty {
            // Safety net: in-memory is empty but disk has notes. This is the failure
            // pattern that historically wiped saved work — refuse the write and log loudly.
            persistenceError = "Refused to replace \(diskSnapshotByID.count) persisted notes with an unexpected empty snapshot."
            return
        }

        persistCurrentNotes()
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
        return [SegmentRange(surface: note.content)]
    }

    // Persists the current notes array to disk synchronously. Diffs against the last-known
    // on-disk state so only changed/added notes are rewritten and removed notes are deleted.
    // Synchronous so a follow-up save can't race a pending detached writer and lose data
    // (the previous detached-task approach allowed regenerate-style "clear then write"
    // pairs to interleave incorrectly).
    private func save() {
        if notes.isEmpty, diskSnapshotByID.isEmpty == false, allowEmptySave == false {
            // Same guard as flushPendingSave: refuse to overwrite populated disk state
            // with an empty in-memory state. The only legitimate way to clear all notes is
            // through `replaceAll(with: [])`, which resets diskSnapshotByID alongside.
            // If we reach this branch the in-memory state is stale or there's a bug, and
            // refusing the write is the safer default.
            persistenceError = "Refused to replace \(diskSnapshotByID.count) persisted notes with an unexpected empty snapshot."
            return
        }

        persistCurrentNotes()
    }

    // Commits the current collection and advances the confirmed disk snapshot
    // only after every file mutation and the ordering index succeed.
    private func persistCurrentNotes() {
        do {
            try NotesStore.writeFiles(
                notes: notes,
                previousSnapshot: diskSnapshotByID,
                directory: directoryURL,
                indexURL: indexURL,
                fileManager: fileManager,
                fileWriter: fileWriter
            )
            diskSnapshotByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            persistenceError = nil
            let deletions = pendingAttachmentDeletions
            pendingAttachmentDeletions = []
            deleteAttachments(deletions)
        } catch {
            persistenceError = Self.persistenceMessage(for: error)
        }
    }

    // Produces a stable user-facing description for a failed persistence operation.
    private static func persistenceMessage(for error: Error) -> String {
        "Notes could not be saved: \(error.localizedDescription)"
    }

    // MARK: - Disk

    // Writes the current notes set as one JSON file per note plus an _index.json recording
    // ordering. Only writes notes that changed vs `previousSnapshot`; only deletes files
    // for notes that were previously written by this app and no longer appear. Orphan
    // files (e.g. corrupt or unindexed) are intentionally left in place so a one-time
    // decode failure doesn't compound into permanent deletion.
    // Runs on the main actor so Note's @MainActor-isolated Codable conformance is honored
    // (project default isolation is @MainActor); keeping it nonisolated would cross actor
    // boundaries on the encode and trip a Swift 6 warning.
    private static func writeFiles(
        notes: [Note],
        previousSnapshot: [UUID: Note],
        directory: URL,
        indexURL: URL,
        fileManager: FileManager,
        fileWriter: any NotesFileWriting
    ) throws {
        ensureDirectoryExists(at: directory, fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let currentIDs = Set(notes.map { $0.id })

        // Write changed / new notes.
        for note in notes {
            if previousSnapshot[note.id] == note { continue }
            let url = directory.appendingPathComponent("\(note.id.uuidString).json", isDirectory: false)
            let data = try encoder.encode(note)
            try fileWriter.write(data, to: url)
        }

        // Remove notes we previously owned but are no longer present.
        for id in previousSnapshot.keys where currentIDs.contains(id) == false {
            let url = directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                try fileWriter.removeItem(at: url)
            }
        }

        // Rewrite the index so order survives relaunch.
        let orderedIDs = notes.map { $0.id.uuidString }
        let indexData = try encoder.encode(orderedIDs)
        try fileWriter.write(indexData, to: indexURL)
    }

    // Reads notes from disk using `_index.json` for ordering. Skips files that fail to
    // decode rather than failing the whole load — a single corrupt note doesn't take down
    // the rest. Falls back to alphabetical UUID order when the index is missing or corrupt.
    // Main-actor for the same Codable-isolation reason as writeFiles.
    private static func readNotesFromFiles(
        directory: URL,
        indexURL: URL,
        fileManager: FileManager
    ) -> [Note] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Discover all note JSON files (excluding the index itself).
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let noteFileURLs = contents.filter { url in
            url.pathExtension == "json" && url.lastPathComponent != "_index.json"
        }

        var notesByID: [UUID: Note] = [:]
        for url in noteFileURLs {
            let basename = url.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: basename) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let note = try decoder.decode(Note.self, from: data)
                notesByID[id] = note
            } catch {
                // Single-note decode failure is loud but non-destructive: file stays on
                // disk for a future build to interpret; the rest of the collection loads.
                print("[NotesStore] could not decode note \(id): \(error)")
            }
        }

        if notesByID.isEmpty { return [] }

        // Apply the index ordering. Notes present on disk but missing from the index
        // tail-append in UUID order (deterministic so users see a stable list).
        var orderedIDs: [UUID] = []
        if let indexData = try? Data(contentsOf: indexURL),
           let raw = try? decoder.decode([String].self, from: indexData) {
            orderedIDs = raw.compactMap { UUID(uuidString: $0) }
        }
        let seen = Set(orderedIDs)
        let tail = notesByID.keys.filter { seen.contains($0) == false }
            .sorted(by: { $0.uuidString < $1.uuidString })
        let finalOrder = orderedIDs + tail
        return finalOrder.compactMap { notesByID[$0] }
    }

    // Reads legacy UserDefaults data for one-time migration. Never written back to UD so
    // a downgrade can still see whatever was last persisted under the old layout.
    private static func readNotesFromLegacyUserDefaults(key: String) -> [Note] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else {
            return []
        }
        return decoded
    }

    // Creates the notes directory if it doesn't exist. Best-effort; surface failures to
    // the console and let downstream writes retry.
    nonisolated private static func ensureDirectoryExists(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) == false else { return }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            print("[NotesStore] could not create notes directory: \(error)")
        }
    }

    // Resolves the per-app Application Support root. Falls back to the temp directory on
    // permission failure so the app keeps running rather than crashing on init.
    nonisolated private static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return url
        }
        return fileManager.temporaryDirectory
    }
}
