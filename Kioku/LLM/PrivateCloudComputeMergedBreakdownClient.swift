import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
// Runs MergedCorrectionBreakdownService's combined breakdown+segmentation prompt through Apple
// Intelligence's Private Cloud Compute model (iOS 27+) instead of the small on-device
// SystemLanguageModel — PCC is a full cloud-hosted model reached through the same FoundationModels
// session API, so it isn't subject to the wide-structured-output limitation that excludes the
// on-device model from this feature (see MergedCorrectionBreakdownService.generate). Mirrors
// PrivateCloudComputeBreakdownClient's session shape: the combined system prompt becomes the
// session's instructions, the combined user message is the per-call prompt.
@available(iOS 27.0, *)
enum PrivateCloudComputeMergedBreakdownClient {
    // Streams the combined response and returns the complete raw text, matching the return
    // contract of LLMStreamingClient.streamOpenAI/streamClaude so
    // MergedCorrectionBreakdownService.parseCombined can consume it unchanged. `onPartialLines`
    // fires with the breakdown half's parsed lines only, truncated at responseDelimiter the same
    // way MergedCorrectionBreakdownService.makeDeltaHandler does for the remote-provider streams —
    // PCC's ResponseStream snapshots are cumulative, so each snapshot is re-split from scratch
    // rather than accumulated fragment by fragment.
    static func generate(
        systemPrompt: String,
        userMessage: String,
        temperature: Double,
        onPartialLines: (@Sendable ([SongLine]) -> Void)? = nil
    ) async throws -> String {
        let session = LanguageModelSession(
            model: PrivateCloudComputeLanguageModel(),
            instructions: systemPrompt
        )
        let options = GenerationOptions(temperature: temperature)
        let parser = SongBreakdownParser()
        let delimiter = MergedCorrectionBreakdownService.responseDelimiter
        // Only used for its recordEmitted dedup — ResponseStream snapshots are already
        // cumulative, unlike LLMStreamingClient's delta fragments, so append(_:)'s
        // fragment-accumulation isn't needed here.
        let accumulator = StreamedTextAccumulator()

        var finalText = ""
        for try await snapshot in session.streamResponse(to: userMessage, options: options) {
            let text = snapshot.content
            finalText = text
            guard let onPartialLines else { continue }
            let breakdownText: String
            if let delimiterRange = text.range(of: delimiter) {
                // The segmentation half has started arriving — the breakdown half is complete
                // and won't change further, matching makeDeltaHandler's suppression once the
                // delimiter is in the buffer.
                breakdownText = String(text[..<delimiterRange.lowerBound])
            } else if let lastNewline = text.lastIndex(of: "\n") {
                // Parse only up to the last completed line — an unterminated tail line's text
                // can still change on the next snapshot.
                breakdownText = String(text[...lastNewline])
            } else {
                continue
            }
            let lines = parser.parsePartial(markdown: breakdownText)
            if accumulator.recordEmitted(lines) {
                onPartialLines(lines)
            }
        }
        return finalText
    }
}
#endif
