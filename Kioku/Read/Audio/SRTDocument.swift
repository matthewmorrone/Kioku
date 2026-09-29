import SwiftUI
import UniformTypeIdentifiers

struct SRTDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.subripText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            text = ""
            return
        }

        text = SubtitleSourceLoader.decodeText(data)
    }

    // Serialises the SRT text back to UTF-8 bytes so the document can be saved or shared.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    // Explicit `nonisolated` because this file imports SwiftUI, which under Swift 6
    // makes top-level extension members default to @MainActor — and
    // FileDocument.readableContentTypes (which references this) is a nonisolated
    // protocol requirement. Evaluated once at first access; UTType is Sendable.
    nonisolated static let subripText: UTType = UTType(filenameExtension: "srt") ?? .plainText
}
