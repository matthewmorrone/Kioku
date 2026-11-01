import SwiftUI

// The Notes tab's folder UI: folder rows at the top level, a back row inside a folder, the
// "move to folder" menus, and the create/rename/delete actions. Folder state (`openFolderID`,
// `folderEditor`, `folderNameDraft`) is declared in NotesView.swift because extensions can't
// hold stored properties. Folders only group notes; deleting one never deletes a note.
extension NotesView {
    // The folder currently open, if any.
    var openFolder: NoteFolder? {
        store.folders.first { $0.id == openFolderID }
    }

    // Top-of-list rows: a back row inside a folder, otherwise one row per folder.
    @ViewBuilder
    var folderHeaderRows: some View {
        if let openFolder {
            Button {
                openFolderID = nil
            } label: {
                Label("All Notes", systemImage: "chevron.backward")
            }
            Label(openFolder.name, systemImage: "folder")
                .font(.headline)
                .foregroundStyle(.secondary)
            if displayedNotes.isEmpty {
                Text("No notes in this folder yet. Use a note's menu to move it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(store.folders) { folder in
                Button {
                    openFolderID = folder.id
                } label: {
                    HStack {
                        Label(folder.name, systemImage: "folder")
                        Spacer(minLength: 0)
                        Text("\(store.noteCount(inFolder: folder.id))")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        folderNameDraft = folder.name
                        folderEditor = .rename(folderID: folder.id)
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.deleteFolder(id: folder.id)
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.deleteFolder(id: folder.id)
                    } label: {
                        Label("Delete Folder", systemImage: "trash")
                    }
                }
            }
        }
    }

    // Menu that files the given notes in a folder, makes a new folder for them, or takes them out
    // of their folder. Shared by the per-note context menu and the multi-select toolbar.
    @ViewBuilder
    func moveToFolderMenu(for noteIDs: Set<UUID>) -> some View {
        Menu {
            ForEach(store.folders) { folder in
                Button {
                    store.moveNotes(ids: noteIDs, toFolder: folder.id)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
            }
            Button {
                folderNameDraft = ""
                folderEditor = .create(moveNoteIDs: noteIDs)
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            if openFolderID != nil {
                Button {
                    store.moveNotes(ids: noteIDs, toFolder: nil)
                } label: {
                    Label("Remove from Folder", systemImage: "tray")
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }

    // Applies the folder alert's Save: creates (and fills) or renames.
    func commitFolderEdit(_ editor: NoteFolderEditor, name: String) {
        switch editor {
        case .create(let moveNoteIDs):
            guard let folder = store.createFolder(name: name) else { return }
            store.moveNotes(ids: moveNoteIDs, toFolder: folder.id)
            selectedNoteIDs.subtract(moveNoteIDs)
        case .rename(let folderID):
            store.renameFolder(id: folderID, name: name)
        }
    }
}
