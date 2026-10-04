import SwiftUI
import UniformTypeIdentifiers

// The Custom Words list as a file for the share/export sheet, written as extras.json
// (CustomWordsExtrasCodec).
struct ExtrasJSONDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let words: [CustomWord]

    // Wraps the list being exported.
    init(words: [CustomWord]) {
        self.words = words
    }

    // Reads a picked file; Custom Words imports through fileImporter instead, so this only exists
    // because FileDocument requires it.
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        words = try CustomWordsExtrasCodec.decode(data)
    }

    // Encodes the list for the exporter.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try CustomWordsExtrasCodec.encode(words))
    }
}
