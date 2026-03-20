import Foundation

// Calls the configured LLM provider to obtain segmentation and reading corrections for a note.
// Supports OpenAI chat completions and Anthropic Messages APIs with a compact human-readable format.
final class LLMCorrectionService {

    // Submits the note's current segmentation in compact format to the active LLM provider
    // and returns a parsed correction response, or throws a descriptive error on failure.
    func requestCorrections(
        compactSegments: String
    ) async throws -> LLMCorrectionResponse {
        let provider = LLMSettings.activeProvider()
        guard let apiKey = LLMSettings.activeAPIKey() else {
            throw LLMCorrectionError.noKeyConfigured
        }

        let messages = buildMessages(compactSegments: compactSegments)

        print("[LLM] System:\n\(messages.system)")
        print("[LLM] User:\n\(messages.user)")

        switch provider {
        case .none:
            throw LLMCorrectionError.noKeyConfigured
        case .openAI:
            return try await callOpenAI(apiKey: apiKey, messages: messages)
        case .claude:
            return try await callClaude(apiKey: apiKey, messages: messages)
        }
    }

    // Compact format: segments separated by `|`, kanji runs annotated as `(kanji)[reading]`.
    // Example: 食べる|は|(情報)[じょうほう]|(生)[い]き(方)[かた]
    static let systemPrompt = """
        You are an expert Japanese linguist. \
        You will be given Japanese text and its current morphological segmentation with readings. \
        Correct any segmentation or reading errors so the result is optimal for a native Japanese reader.

        SEGMENT FORMAT:
        - Segments are separated by |
        - Kanji within a segment are annotated as (kanji)[reading] where reading is hiragana only
        - Okurigana (trailing/internal kana) are left outside the parentheses, e.g. 食べる → (食)[た]べる, 生き方 → (生)[い]き(方)[かた]
        - Pure kana, numbers, punctuation, and whitespace: no annotation, just the text
        - Whitespace characters, newlines, and punctuation must each be their own segment

        OUTPUT RULES:
        - Return ONLY the corrected compact format string, nothing else — no explanation, no markdown
        - All segment surfaces must concatenate in order to reproduce the original text exactly, character-for-character
        - Never add, remove, or alter any character from the original text
        """

    // Constructs system and user message content for the correction request.
    private func buildMessages(compactSegments: String) -> (system: String, user: String) {
        return (system: Self.systemPrompt, user: compactSegments)
    }

    // Calls OpenAI chat completions. No json_object response_format — compact text output.
    private func callOpenAI(apiKey: String, messages: (system: String, user: String)) async throws -> LLMCorrectionResponse {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": messages.system],
                ["role": "user", "content": messages.user]
            ],
            "max_tokens": 4096,
            "temperature": 0.2
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data, provider: "OpenAI")

        // OpenAI wraps the model output in choices[0].message.content as a string.
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw LLMCorrectionError.unexpectedResponseShape("OpenAI response missing choices[0].message.content")
        }

        print("[LLM:OpenAI] Response:\n\(content)")
        return try parseCompactResponse(content)
    }

    // Calls the Anthropic Messages API using the current stable claude-opus-4-6 model.
    private func callClaude(apiKey: String, messages: (system: String, user: String)) async throws -> LLMCorrectionResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "claude-opus-4-6",
            "max_tokens": 4096,
            "temperature": 0.2,
            "system": messages.system,
            "messages": [
                ["role": "user", "content": messages.user]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data, provider: "Claude")

        // Anthropic wraps the model output in content[0].text as a string.
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let firstBlock = content.first,
            let text = firstBlock["text"] as? String
        else {
            throw LLMCorrectionError.unexpectedResponseShape("Claude response missing content[0].text")
        }

        print("[LLM:Claude] Response:\n\(text)")
        return try parseCompactResponse(text)
    }

    // Validates the HTTP status code and surfaces the API error body when the request fails.
    private func validateHTTPResponse(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMCorrectionError.networkError("\(provider): non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(unreadable)"
            throw LLMCorrectionError.networkError("\(provider) HTTP \(http.statusCode): \(body)")
        }
    }

    // Parses the compact format string returned by the LLM into [LLMSegmentEntry].
    // Format: segments separated by `|`, kanji annotated as `(kanji)[reading]`.
    // Each segment surface is reconstructed by stripping the annotation brackets.
    func parseCompactResponse(_ compact: String) throws -> LLMCorrectionResponse {
        // Trim whitespace/newlines the model may have added around the output.
        let trimmed = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSegments = trimmed.components(separatedBy: "|")

        var entries: [LLMSegmentEntry] = []
        for raw in rawSegments {
            // Skip empty strings produced by trailing `|` or double `||`.
            guard raw.isEmpty == false else { continue }
            let (surface, reading) = parseSegmentToken(raw)
            entries.append(LLMSegmentEntry(surface: surface, reading: reading))
        }

        guard entries.isEmpty == false else {
            throw LLMCorrectionError.decodingError("Compact response produced no segments. Raw: \(compact.prefix(300))")
        }

        return LLMCorrectionResponse(segments: entries)
    }

    // Parses one segment token like `(食)[た]べる|は|(情報)[じょうほう]` into (surface, reading).
    // Surface: all characters outside and inside `()` brackets, no `[]` content.
    // Reading: all `[...]` content concatenated in order.
    private func parseSegmentToken(_ token: String) -> (surface: String, reading: String) {
        var surface = ""
        var reading = ""
        var i = token.startIndex

        while i < token.endIndex {
            let ch = token[i]
            if ch == "(" {
                // Kanji run: collect surface inside `(...)`.
                let afterOpen = token.index(after: i)
                if let closeIdx = token[afterOpen...].firstIndex(of: ")") {
                    let kanjiText = String(token[afterOpen..<closeIdx])
                    surface += kanjiText
                    i = token.index(after: closeIdx)
                    // Expect `[reading]` immediately after `)`.
                    if i < token.endIndex, token[i] == "[" {
                        let afterBracket = token.index(after: i)
                        if let closeBracket = token[afterBracket...].firstIndex(of: "]") {
                            reading += String(token[afterBracket..<closeBracket])
                            i = token.index(after: closeBracket)
                        }
                    }
                } else {
                    // Malformed — treat `(` as literal.
                    surface.append(ch)
                    i = token.index(after: i)
                }
            } else if ch == "[" {
                // Stray `[reading]` not preceded by `()` — skip bracket content.
                let afterBracket = token.index(after: i)
                if let closeBracket = token[afterBracket...].firstIndex(of: "]") {
                    i = token.index(after: closeBracket)
                } else {
                    i = token.index(after: i)
                }
            } else {
                surface.append(ch)
                i = token.index(after: i)
            }
        }

        return (surface, reading)
    }
}

// Enumerates error cases that can arise during an LLM correction request.
enum LLMCorrectionError: LocalizedError {
    case noKeyConfigured
    case networkError(String)
    case unexpectedResponseShape(String)
    case decodingError(String)

    // Human-readable message surfaced in the UI alert.
    var errorDescription: String? {
        switch self {
        case .noKeyConfigured:
            return "No API key configured. Add one in Settings."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .unexpectedResponseShape(let msg):
            return "Unexpected API response: \(msg)"
        case .decodingError(let msg):
            return "Could not parse response: \(msg)"
        }
    }
}
