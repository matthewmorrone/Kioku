import Foundation

// Requests a segmentation + reading correction for one note from the configured remote provider
// (gpt-5.6-luna, or Claude Sonnet 5 in debug builds). Sends the note's CURRENT segmentation in
// LLMCorrectionFormat's compact format — manual edits included — and streams the corrected
// compact text back, reporting each completed line so the Read tab can highlight where the model
// is and stage that line's suggestions as they arrive. Nothing here touches the document: the
// caller parses and stages the result as pending changes for the user to confirm or reject.
nonisolated enum LLMCorrectionClient {
    // Answer-sized cap for the corrected compact text, which runs roughly the size of the input.
    // Reasoning models get their own headroom on top (see OpenAI/ClaudeRequestParameters).
    static let maxTokens = 16384

    // Streams the correction. `onCompletedText` receives the response up to its last completed
    // line each time a line finishes (the unterminated tail is never passed on). Returns the full
    // raw response. In stub mode (LLM off) returns the stored stub response without a request.
    static func requestCorrection(
        compactSegments: String,
        onCompletedText: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        if LLMSettings.isEnabled() == false {
            return UserDefaults.standard.string(forKey: LLMSettings.stubResponseKey) ?? ""
        }
        let provider = LLMSettings.remoteProvider()
        guard let apiKey = LLMSettings.apiKey(for: provider) else {
            throw SongBreakdownError.noKeyConfigured
        }
        let accumulator = StreamedTextAccumulator()
        let onDelta: @Sendable (String) -> Void = { fragment in
            if let completed = accumulator.append(fragment) {
                onCompletedText(completed)
            }
        }
        let urlSession = LLMStreamingClient.makeLongTimeoutSession()

        switch provider {
        case .openAI:
            return try await LLMStreamingClient.streamOpenAI(
                apiKey: apiKey,
                model: LLMSettings.openAIModel(),
                messages: [
                    ["role": "system", "content": LLMCorrectionFormat.systemPrompt],
                    ["role": "user", "content": compactSegments]
                ],
                maxTokens: maxTokens,
                urlSession: urlSession,
                onDelta: onDelta
            )
        case .claude:
            return try await LLMStreamingClient.streamClaude(
                apiKey: apiKey,
                model: LLMSettings.claudeModel(),
                system: [[
                    "type": "text",
                    "text": LLMCorrectionFormat.systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]],
                userContent: compactSegments,
                maxTokens: maxTokens,
                urlSession: urlSession,
                onDelta: onDelta
            )
        case .none, .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro:
            // Unreachable: none and every Apple variant have no API key, caught above.
            throw SongBreakdownError.noKeyConfigured
        }
    }

    // How many note lines a partial compact response has finished — the highest `N|` record
    // number seen, so the line being written now is the next one (0-based index = this count).
    static func completedLineCount(in partial: String) -> Int {
        partial.components(separatedBy: "\n").reduce(0) { highest, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let bar = trimmed.firstIndex(of: "|"), let number = Int(trimmed[..<bar]) else { return highest }
            return max(highest, number)
        }
    }
}
