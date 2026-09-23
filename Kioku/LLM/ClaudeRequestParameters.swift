import Foundation

// The length and reasoning parameters a Claude Messages request sends. Current Claude models
// (Sonnet 5, Opus 5) reason by default at high effort, and that hidden reasoning spends from
// max_tokens: a one-shot song breakdown test (2026-09-23) had Sonnet 5 spend its whole 8,192-token
// cap reasoning and return no breakdown text at all. So effort-capable models get low effort
// (transcription-and-gloss work doesn't need deep reasoning) plus headroom on top of the caller's
// answer-sized cap. Haiku 4.5 predates effort and rejects the parameter, so it keeps the plain
// shape.
nonisolated enum ClaudeRequestParameters {
    // Room for low-effort reasoning on top of the visible answer's cap.
    static let reasoningHeadroomTokens = 8192
    static let effort = "low"

    // True for models that take `output_config.effort` (everything current except Haiku 4.5).
    static func supportsEffort(_ model: String) -> Bool {
        model.hasPrefix("claude-haiku") == false
    }

    // Adds max_tokens (and, where supported, low effort with reasoning headroom) to a request body.
    static func apply(to body: inout [String: Any], model: String, maxTokens: Int) {
        if supportsEffort(model) {
            body["max_tokens"] = maxTokens + reasoningHeadroomTokens
            body["output_config"] = ["effort": effort]
        } else {
            body["max_tokens"] = maxTokens
        }
    }
}
