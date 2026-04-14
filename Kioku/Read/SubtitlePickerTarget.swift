import UniformTypeIdentifiers

// Identifies which file type the subtitle popup's file importer should present.
// SwiftUI only supports one .fileImporter per view, so this enum routes
// both audio and subtitle file picks through a single modifier.
enum SubtitlePickerTarget {
    case audio
    case subtitleFile

    var contentTypes: [UTType] {
        switch self {
        case .audio:
            return [.audio, .mpeg4Audio, .mp3]
        case .subtitleFile:
            return [UTType(filenameExtension: "srt") ?? .plainText, .plainText]
        }
    }
}
