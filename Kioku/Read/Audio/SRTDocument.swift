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

        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let utf16 = String(data: data, encoding: .utf16) {
            text = utf16
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            text = latin1
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
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
