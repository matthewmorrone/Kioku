import Foundation
import Combine

// Defines supported merge strategies when importing notes from a transfer document.
enum NotesImportMode: String, CaseIterable {
    case replaceAll
    case overwriteByID
    case overwriteByTitle
    case append

    // Provides a user-facing title for import mode selection UI.
    var title: String {
        switch self {
        case .replaceAll:
            return "Replace All"
        case .overwriteByID:
            return "Overwrite by ID"
        case .overwriteByTitle:
            return "Overwrite by Title"
        case .append:
            return "Append"
        }
    }

    // Provides a concise explanation shown alongside each import mode option.
    var detail: String {
        switch self {
        case .replaceAll:
            return "Discard all current notes and replace with imported notes."
        case .overwriteByID:
            return "Update matching note IDs; append imported notes with new IDs."
        case .overwriteByTitle:
            return "Update matching titles; append imported notes with unmatched titles."
        case .append:
            return "Keep all current notes and append all imported notes."
        }
    }

    // Returns a brief status phrase used in import-complete alerts.
    var completionVerb: String {
        switch self {
        case .replaceAll:
            return "Replaced"
        case .overwriteByID:
            return "Merged by ID"
        case .overwriteByTitle:
            return "Merged by Title"
        case .append:
            return "Appended"
        }
    }
}
