import Foundation

// The streaming half of LLMCorrectionService's remote path, split out to keep the service file
// under the line-count guardrail. See requestCorrections for when streaming is chosen.
extension LLMCorrectionService {
    // Streams a remote provider's response (same request shape as the one-shot builders,
    // minus the web-search tool) and, whenever a newline lands, parses every complete line so
    // far and hands the cumulative result to `onPartial` — so the page fills in as the model
    // writes, as it does with Apple Intelligence. Returns the full text for parseWithSalvage.
    func streamRemote(
        provider: LLMProvider,
        apiKey: String,
        messages: (system: String, user: String),
        onPartial: @escaping @Sendable @MainActor (LLMCorrectionResponse) -> Void
    ) async throws -> String {
        let accumulator = StreamedLineAccumulator()
        let onDelta: @Sendable (String) -> Void = { delta in
            guard let completed = accumulator.append(delta) else { return }
            Task { @MainActor in
                if let parsed = try? LLMCorrectionService().parseCompactResponse(completed) { onPartial(parsed) }
            }
        }
        switch provider {
        case .openAI:
            let temperature = UserDefaults.standard.object(forKey: LLMSettings.temperatureKey) as? Double
                ?? LLMSettings.defaultTemperature
            AppLog.debug(.llmCorrection, "[OpenAI] streaming model=\(LLMSettings.openAIModel())")
            return try await LLMStreamingClient.streamOpenAI(
                apiKey: apiKey,
                model: LLMSettings.openAIModel(),
                messages: [
                    ["role": "system", "content": messages.system],
                    ["role": "user", "content": messages.user]
                ],
                maxTokens: 4096,
                temperature: temperature,
                urlSession: urlSession,
                onDelta: onDelta
            )
        case .claude:
            AppLog.debug(.llmCorrection, "[Claude] streaming model=\(LLMSettings.claudeModel())")
            return try await LLMStreamingClient.streamClaude(
                apiKey: apiKey,
                model: LLMSettings.claudeModel(),
                system: [["type": "text", "text": messages.system, "cache_control": ["type": "ephemeral"]]],
                userContent: messages.user,
                maxTokens: 16384,
                urlSession: urlSession,
                onDelta: onDelta
            )
        default:
            throw LLMCorrectionError.noKeyConfigured
        }
    }

}
