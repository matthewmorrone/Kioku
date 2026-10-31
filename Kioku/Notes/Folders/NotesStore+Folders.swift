import SwiftUI

// Folder operations for the notes collection. Folders never own notes: a note only carries a
// `folderID`, so removing a folder files its notes back at the top level and can never delete one.
extension NotesStore {
    // True when the id names a folder that currently exists.
    func hasFolder(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return folders.contains { $0.id == id }
    }

    // Notes shown for one scope: a folder's own notes, or (nil) the top level, which also gathers
    // notes whose folder no longer exists so a stale id can never hide a note.
    func notes(inFolder folderID: UUID?) -> [Note] {
        guard let folderID else {
            return notes.filter { hasFolder($0.folderID) == false }
        }
        return notes.filter { $0.folderID == folderID }
    }

    // How many notes a folder holds, for the row subtitle.
    func noteCount(inFolder folderID: UUID) -> Int {
        notes.reduce(0) { $0 + ($1.folderID == folderID ? 1 : 0) }
    }

    // Creates a folder from a user-typed name; blank names are refused. Returns the new folder.
    @discardableResult
    func createFolder(name: String) -> NoteFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let folder = NoteFolder(name: trimmed)
        folders.append(folder)
        saveFolders()
        return folder
    }

    // Renames a folder; a blank name leaves it unchanged.
    func renameFolder(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        saveFolders()
    }

    // Removes a folder and files its notes back at the top level. Notes are never deleted here.
    func deleteFolder(id: UUID) {
        notes = notes.map { note in
            guard note.folderID == id else { return note }
            var unfiled = note
            unfiled.folderID = nil
            return unfiled
        }
        folders.removeAll { $0.id == id }
        saveFolders()
    }

    // Files the given notes into a folder, or at the top level when `folderID` is nil.
    func moveNotes(ids: Set<UUID>, toFolder folderID: UUID?) {
        guard ids.isEmpty == false else { return }
        let destination = hasFolder(folderID) ? folderID : nil
        notes = notes.map { note in
            guard ids.contains(note.id), note.folderID != destination else { return note }
            var moved = note
            moved.folderID = destination
            return moved
        }
    }

    // Drag-reorders within one scope. The scope's notes are reordered among the slots they already
    // occupy in the full list, so notes in other folders keep their places.
    func moveNotes(inFolder folderID: UUID?, from source: IndexSet, to destination: Int) {
        var scoped = notes(inFolder: folderID)
        scoped.move(fromOffsets: source, toOffset: destination)
        let scopedIDs = Set(scoped.map(\.id))
        var reordered = scoped.makeIterator()
        notes = notes.map { note in
            scopedIDs.contains(note.id) ? (reordered.next() ?? note) : note
        }
    }

    // Replaces the whole folder list (backup restore, reset) and persists it.
    func replaceFolders(with newFolders: [NoteFolder]) {
        folders = newFolders
        saveFolders()
    }

    // Persists the folder list; a failure is surfaced through `persistenceError` like note writes.
    private func saveFolders() {
        do {
            try NoteFolderFile.save(folders, directory: directoryURL, fileWriter: fileWriter)
        } catch {
            persistenceError = "Folders could not be saved: \(error.localizedDescription)"
            AppLog.error(.storage, "[NotesStore] could not save folders: \(error)")
        }
    }
}
