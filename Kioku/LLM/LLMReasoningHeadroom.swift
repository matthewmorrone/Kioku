import Foundation

// Shared token headroom every reasoning-capable request builder (Claude, OpenAI) adds on top of
// the caller's answer-sized cap. Reasoning spends from the same cap as the visible answer, so
// without this headroom a reasoning model's hidden thinking can consume the whole budget and
// return no answer text at all — confirmed 2026-09-23 when Sonnet 5 did exactly that on an
// 8,192-token cap with no headroom. Centralized so the two providers can't drift apart on it.
nonisolated enum LLMReasoningHeadroom {
    static let tokens = 8192
}
