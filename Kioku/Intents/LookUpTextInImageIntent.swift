import AppIntents
import UniformTypeIdentifiers

// "Look up text in an image": reads the Japanese text in a photo or screenshot with the same OCR
// the Notes import uses, then opens it in the Words search. The recognized text is also returned
// so a shortcut can pass it on.
struct LookUpTextInImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Look Up Text in Image"
    static let description = IntentDescription("Recognizes the text in an image and looks it up in the dictionary.")
    static let openAppWhenRun = true

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    // Runs OCR off the main actor, then raises the lookup on the main actor.
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let data = image.data
        let recognized = try await Task.detached(priority: .userInitiated) {
            try OCRTextRecognizer.recognizeText(in: data)
        }.value
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw KiokuIntentError.noTextInImage }
        await MainActor.run { IntentRouter.shared.pending = .lookUp(trimmed) }
        return .result(value: trimmed)
    }
}
