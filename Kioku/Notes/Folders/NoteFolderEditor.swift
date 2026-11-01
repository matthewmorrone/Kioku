import Foundation

// What the folder-name alert is doing: making a new folder (optionally filing notes into it as it
// is created) or renaming an existing one. Pure data.
enum NoteFolderEditor: Equatable {
    case create(moveNoteIDs: Set<UUID>)
    case rename(folderID: UUID)
}
