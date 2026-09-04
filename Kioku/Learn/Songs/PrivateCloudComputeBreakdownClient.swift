import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
// Runs SongBreakdownService's exact prompt through Apple Intelligence's Private Cloud Compute
// model (iOS 27+) instead of the small on-device SystemLanguageModel — PCC is a full cloud-hosted
// model reached through the same FoundationModels session API, so it isn't subject to the
// wide-structured-output limitation that excludes the on-device model from this feature (see
// SongBreakdownService.generate). Mirrors the Claude path's system/user split: the large static
// instructions become the session's instructions, the raw lyrics are the per-call prompt.
@available(iOS 27.0, *)
enum PrivateCloudComputeBreakdownClient {
    // Streams a breakdown for `lyrics` and returns the complete raw markdown, matching the
    // return contract of LLMStreamingClient.streamOpenAI/streamClaude. `onPartialLines` fires
    // whenever a new completed line changes the parsed result, same as the remote-provider path.
    static func generate(
        lyrics: String,
        temperature: Double,
        onPartialLines: (@Sendable ([SongLine]) -> Void)? = nil
    ) async throws -> String {
        let session = LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            instructions: SongBreakdownPrompt.staticInstructions()
        )
        let options = GenerationOptions(temperature: temperature)
        let parser = SongBreakdownParser()
        // Only used for its recordEmitted dedup — ResponseStream snapshots are already
        // cumulative, unlike LLMStreamingClient's delta fragments, so append(_:)'s
        // fragment-accumulation isn't needed here.
        let accumulator = StreamedTextAccumulator()

        var finalText = ""
        for try await snapshot in session.streamResponse(to: lyrics, options: options) {
            let text = snapshot.content
            finalText = text
            guard let onPartialLines, let lastNewline = text.lastIndex(of: "\n") else { continue }
            // Parse only up to the last completed line — an unterminated tail line's text can
            // still change on the next snapshot (see StreamedTextAccumulator.append's doc comment).
            let stable = String(text[...lastNewline])
            let lines = parser.parsePartial(markdown: stable)
            if accumulator.recordEmitted(lines) {
                onPartialLines(lines)
            }
        }
        return finalText
    }
}
#endif
