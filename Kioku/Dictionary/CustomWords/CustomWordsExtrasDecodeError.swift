import Foundation

// A file CustomWordsExtrasCodec can't read as an extras.json word list.
nonisolated enum CustomWordsExtrasDecodeError: LocalizedError {
    case notExtrasJSON
    case entryNotObject(Int)

    // The message the Custom Words import alert shows.
    var errorDescription: String? {
        switch self {
        case .notExtrasJSON: return "The file isn't an extras.json word list."
        case .entryNotObject(let index): return "Entry \(index + 1) in the file isn't a word."
        }
    }
}
