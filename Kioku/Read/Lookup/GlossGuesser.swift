import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Guesses an English gloss for a word the dictionary has no entry for (a French loanword in a lyric,
// a coined spelling), so the lookup sheet shows something instead of an empty middle. A gloss
// already stored for the surface in that line is used as is; otherwise an AI request (the configured
// remote provider, else on-device Apple Intelligence, which is also used when AI features are
// turned off) gets the word's line as context, plus the note's
// song breakdown explanation of the word when there is one. The breakdown text itself is not shown:
// it's written to be read aloud and runs well past a gloss ("…, often symbolizes clarity or
// revelation"). Every failure returns nil and the sheet stays as it was.
enum GlossGuesser {
    private static let maxGlossLength = 120

    // Returns a guessed gloss for `surface`, storing any new AI guess so it's asked for only once.
    @MainActor
    static func guess(
        surface: String,
        lineContext: String,
        breakdownWords: [SongWord],
        store: GuessedGlossStore = .shared
    ) async -> String? {
        if let stored = store.gloss(for: surface, in: lineContext) { return stored }
        let breakdownNote = breakdownWords.first(where: { $0.surface == surface })?.definition
        let request = prompt(surface: surface, lineContext: lineContext, breakdownNote: breakdownNote)
        // With AI features turned off, the remote providers are off limits, but the on-device model
        // is free and private, and a labelled guess beats an empty sheet.
        let reply = LLMSettings.isEnabled() ? await askModel(prompt: request) : await askOnDeviceModel(prompt: request)
        guard let reply, let gloss = cleaned(reply) else { return nil }
        store.setGloss(gloss, for: surface, in: lineContext)
        return gloss
    }

    // The request: one short gloss, with the source word named when it's a loanword.
    static func prompt(surface: String, lineContext: String, breakdownNote: String? = nil) -> String {
        let note = breakdownNote.map { "\nA longer explanation of it from a song breakdown: \($0)" } ?? ""
        return """
        This Japanese text has no dictionary entry for the word 「\(surface)」: \(lineContext)\(note)
        Give a short English gloss for 「\(surface)」 as used here (at most 8 words). If it is a \
        loanword, add the source language and word in parentheses, like: light (French 'lumière'). \
        Reply with the gloss only.
        """
    }

    // First line of the model's reply without wrapping quotes, or nil when that's empty or too long
    // to be a gloss.
    static func cleaned(_ raw: String) -> String? {
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"“”「」")))
        guard trimmed.isEmpty == false, trimmed.count <= maxGlossLength else { return nil }
        return trimmed
    }

    // Sends the prompt to the configured remote provider, or on-device Apple Intelligence when no
    // remote provider is set up. nil when neither is available or the request fails.
    private static func askModel(prompt: String) async -> String? {
        let provider = LLMSettings.remoteProvider()
        if let apiKey = LLMSettings.apiKey(for: provider), apiKey.isEmpty == false {
            let session = LLMStreamingClient.makeLongTimeoutSession()
            do {
                switch provider {
                case .openAI:
                    return try await LLMStreamingClient.streamOpenAI(
                        apiKey: apiKey,
                        model: LLMSettings.openAIModel(),
                        messages: [["role": "user", "content": prompt]],
                        maxTokens: 60,
                        urlSession: session,
                        onDelta: { _ in }
                    )
                case .claude:
                    return try await LLMStreamingClient.streamClaude(
                        apiKey: apiKey,
                        model: LLMSettings.claudeModel(),
                        system: [["type": "text", "text": "You gloss Japanese words in English."]],
                        userContent: prompt,
                        maxTokens: 60,
                        urlSession: session,
                        onDelta: { _ in }
                    )
                case .none, .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro:
                    break
                }
            } catch {
                AppLog.error(.llmCorrection, "gloss guess request failed: \(error)")
                return nil
            }
        }
        return await askOnDeviceModel(prompt: prompt)
    }

    // The on-device fallback: Apple Intelligence's system model, when the device has it ready.
    // Glossing is a transformation of text the user supplied, so it runs under the permissive
    // guardrails: the default ones refuse whole lines of ordinary fiction ("May contain unsafe
    // content") over an insult like 間抜け野郎 elsewhere in the line.
    private static func askOnDeviceModel(prompt: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                let response = try await LanguageModelSession(model: model).respond(
                    to: prompt,
                    options: GenerationOptions(temperature: 0.1)
                )
                return response.content
            } catch {
                AppLog.error(.llmCorrection, "on-device gloss guess failed: \(error)")
            }
        }
        #endif
        return nil
    }
}
