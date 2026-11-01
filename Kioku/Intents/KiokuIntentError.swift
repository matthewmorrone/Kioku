import AppIntents

// Failures an intent reports to Shortcuts/Siri in plain words.
nonisolated enum KiokuIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyText
    case noTextInImage

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyText: return "There was no text to use."
        case .noTextInImage: return "No text was recognized in that image."
        }
    }
}
