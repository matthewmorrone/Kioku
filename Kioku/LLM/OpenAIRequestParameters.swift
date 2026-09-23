import Foundation

// The length and sampling parameters an OpenAI Chat Completions request sends, which differ by
// model family. GPT-5-family models are reasoning models: they reject `max_tokens` (the cap is
// `max_completion_tokens`, which also covers their hidden reasoning), accept only the default
// temperature, and take a `reasoning_effort`. Older models (gpt-4o, gpt-4.1) keep `max_tokens`
// and the user's temperature exactly as before.
nonisolated enum OpenAIRequestParameters {
    // Reasoning spends from the same cap as the visible answer, so a reasoning model gets this
    // much headroom on top of the caller's answer-sized cap rather than having the breakdown cut
    // short by its own thinking.
    static let reasoningHeadroomTokens = 8192
    // Breakdown and correction are transcription-and-gloss work that doesn't need deep
    // reasoning; low effort keeps the hidden (billed) reasoning small.
    static let reasoningEffort = "low"

    // True for the GPT-5 family (gpt-5, gpt-5-mini, gpt-5.6-…).
    static func isReasoningModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-5")
    }

    // Adds the length/sampling parameters for `model` to a request body.
    static func apply(to body: inout [String: Any], model: String, maxTokens: Int, temperature: Double?) {
        if isReasoningModel(model) {
            body["max_completion_tokens"] = maxTokens + reasoningHeadroomTokens
            body["reasoning_effort"] = reasoningEffort
        } else {
            body["max_tokens"] = maxTokens
            if let temperature { body["temperature"] = temperature }
        }
    }
}
