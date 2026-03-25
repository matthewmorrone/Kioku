import Foundation

// Calls the configured LLM provider to obtain segmentation and reading corrections for a note.
// Supports OpenAI chat completions and Anthropic Messages APIs with a compact human-readable format.
final class LLMCorrectionService {

    // Submits the note's current segmentation in compact format to the active LLM provider,
    // or parses the stub response directly when useLLM is off. Throws on misconfiguration.
    func requestCorrections(
        compactSegments: String
    ) async throws -> LLMCorrectionResponse {
        let useLLM = UserDefaults.standard.bool(forKey: LLMSettings.useLLMKey)

        // Stub mode: parse the hand-corrected compact response without any API call.
        // Prefers the in-app text field; falls back to llm_stub.txt in the bundle.
        if useLLM == false {
            let userStub = UserDefaults.standard.string(forKey: LLMSettings.stubResponseKey) ?? ""
            let stub: String
            if userStub.isEmpty == false {
                stub = userStub
            } else if let url = Bundle.main.url(forResource: "llm_stub", withExtension: "txt"),
                      let fileContents = try? String(contentsOf: url, encoding: .utf8) {
                // Strip comment lines so the file can contain explanatory notes.
                let stripped = fileContents
                    .components(separatedBy: .newlines)
                    .filter { !$0.hasPrefix("#") }
                    .joined(separator: "\n")
                stub = stripped
            } else {
                stub = ""
            }
            guard stub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw LLMCorrectionError.noKeyConfigured
            }
            print("[LLM] Input:\n\(compactSegments)")
            print("[LLM] Stub response:\n\(stub)")
            return try parseCompactResponse(stub)
        }

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

    // Compact format: one line per source line, prefixed with a 1-based line number.
    // Example: 1|(食)[た]べる|は|\n2|(情報)[じょうほう]|(生)[い]き(方)[かた]|
    static let systemPrompt = """
        You are an expert Japanese linguist. \
        You will be given Japanese text with a proposed morphological segmentation and readings. \
        The proposed segmentation is produced by an automated tool and may contain errors — treat it as a rough draft, not ground truth. \
        Re-segment the text from scratch using your full understanding of Japanese grammar and context. \
        The goal is the segmentation a skilled native reader would consider correct.
        - DO NOT HESITATE TO SPLIT OR MERGE SEGMENTS WHEN WRONG OR NOT QUITE RIGHT — BE AGGRESSIVE AND ERR ON THE SIDE OF MAKING CHANGES

        SEGMENT FORMAT:
        - Each source line maps to exactly one output line with the same line number
        - Each line starts with its line number N followed by | then the segments: N|seg1|seg2|
        - Example line: 3|(食)[た]べる|は|
        - A blank source line is encoded as N| (line number followed by a bare |)
        - Kanji within a segment are annotated as (kanji)[reading] where reading is hiragana only
        - Okurigana (trailing/internal kana) are left outside the parentheses, e.g. 食べる → (食)[た]べる, 生き方 → (生)[い]き(方)[かた]
        - Pure kana, numbers, punctuation, and whitespace: no annotation, just the text
        - Whitespace characters and punctuation must each be their own segment

        SEGMENTATION GUIDELINES:
        - Compound nouns that form a single lexical unit must stay together: 中学校, 高校生, 東京都, etc.
        - Particles (は, が, を, に, で, も, と, から, まで, より, など, か, ね, よ, な, わ, ぞ, ぜ) must each be their own segment with no exceptions — には, では, とは, からは, etc. are always two separate segments, never one: 時には → (時)[とき]|に|は, 中では → (中)[なか]|で|は
        - Numerals followed by counter words must stay together based on meaning in context: 中二人 → (中)[なか]|(二人)[ふたり] not |(中二)[ちゅうに]|(人)[ひと]|
        - Verb stem and inflectional suffix must stay in one segment: 食べる not 食べ|る, 書いた not 書い|た
        - Compound verbs (verb + verb, or verb + auxiliary) are one segment: 追いつづける, 飛び込む, 言い続ける, 走り出す — never split at the connective 〜い or 〜き form
        - When a sequence can be read as a known verb, prefer that reading over splitting it into a suffix + another word: とじてたしかめて → とじて|たしかめて not とじてた|しかめて (たしかめる is the verb, not しかめる)
        - DO NOT HESITATE TO SPLIT OR MERGE SEGMENTS WHEN WRONG OR NOT QUITE RIGHT — BE AGGRESSIVE AND ERR ON THE SIDE OF MAKING CHANGES

        OUTPUT RULES:
        - Return ONLY the corrected compact format, nothing else — no explanation, no markdown
        - Every output line must start with its line number N followed by | and end with |
        - Output exactly one line per input line, with the same line number — do not merge or reorder lines
        - Segments MUST NOT cross line boundaries — all segments on line N come only from source line N
        - All segment surfaces within a line must concatenate in order to reproduce that source line exactly, character-for-character
        - Never add, remove, or alter any character from the original text — do not convert kana to kanji or kanji to kana, do not normalize, do not substitute
        - Do not insert spaces between segments or anywhere else — if the original has no space, the output must have no space
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

        let temperature = UserDefaults.standard.object(forKey: LLMSettings.temperatureKey) as? Double
            ?? LLMSettings.defaultTemperature
        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                ["role": "system", "content": messages.system],
                ["role": "user", "content": messages.user]
            ],
            "max_tokens": 4096,
            "temperature": temperature
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

        let temperature = UserDefaults.standard.object(forKey: LLMSettings.temperatureKey) as? Double
            ?? LLMSettings.defaultTemperature
        let body: [String: Any] = [
            "model": "claude-opus-4-6",
            "max_tokens": 4096,
            "temperature": temperature,
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
    // Each content line `N|seg1|seg2|` encodes segments followed by an implicit `\n`.
    // A bare `N|` line encodes an extra blank line (an additional `\n` beyond the implicit one).
    // The leading `N|` line-number prefix is optional — lines without it are accepted for
    // backward compat with stub responses that omit line numbers.
    // Example: `1|A|\n2|B|\n3|\n4|C|` → [A, \n, B, \n, \n, C, \n]
    func parseCompactResponse(_ compact: String) throws -> LLMCorrectionResponse {
        let lines = compact.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }

        var entries: [LLMSegmentEntry] = []
        for (lineIndex, line) in lines.enumerated() {
            // Strip optional leading line-number prefix: `N|rest` → `|rest` (or `N|` → `|`).
            // A line-number prefix is a run of ASCII digits followed by `|` at the start.
            let normalized: String
            let digitPrefixCount = line.prefix(while: { $0.isNumber }).count
            if digitPrefixCount > 0 {
                let afterDigits = line.index(line.startIndex, offsetBy: digitPrefixCount)
                if afterDigits < line.endIndex, line[afterDigits] == "|" {
                    normalized = "|" + String(line[line.index(after: afterDigits)...])
                } else {
                    normalized = line
                }
            } else {
                normalized = line
            }

            guard normalized.hasPrefix("|") && normalized.hasSuffix("|") else {
                throw LLMCorrectionError.decodingError(
                    "Line \(lineIndex + 1) must begin and end with |: \"\(line.prefix(60))\""
                )
            }
            let inner = String(normalized.dropFirst().dropLast())
            if inner.isEmpty {
                // Bare `|` encodes an extra blank line in addition to the implicit \n
                // that follows the preceding content line.
                entries.append(LLMSegmentEntry(surface: "\n", reading: ""))
                continue
            }
            let rawSegments = inner.components(separatedBy: "|")
            for raw in rawSegments {
                // Trim spaces the model may pad around segment delimiters.
                let raw = raw.trimmingCharacters(in: .init(charactersIn: " "))
                guard raw.isEmpty == false else { continue }
                let (surface, reading) = parseSegmentToken(raw)
                entries.append(LLMSegmentEntry(surface: surface, reading: reading))
            }
            // Each content line encodes an implicit trailing newline.
            entries.append(LLMSegmentEntry(surface: "\n", reading: ""))
        }

        guard entries.isEmpty == false else {
            throw LLMCorrectionError.decodingError("Compact response produced no segments. Raw: \(compact.prefix(300))")
        }

        return LLMCorrectionResponse(segments: entries)
    }

    // Parses one segment token like `(巡)[めぐ]り(会)[あ]う` into (surface, reading).
    // Surface: kanji + kana exactly as they appear in the source text.
    // Reading: full phonetic reading including kana between kanji runs, so that
    //   projectRunReadings can re-split per run using the okurigana as delimiters.
    // Example: `(巡)[めぐ]り(会)[あ]う` → surface="巡り会う", reading="めぐりあう"
    // Pure-kana tokens (no `()` annotations) produce an empty reading.
    private func parseSegmentToken(_ token: String) -> (surface: String, reading: String) {
        var surface = ""
        var reading = ""
        var hasAnnotation = false
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
                            hasAnnotation = true
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
                // Literal kana (okurigana between or after kanji runs).
                // Include in reading only when the token has annotations, so that
                // projectRunReadings can use the kana as a split delimiter.
                surface.append(ch)
                if hasAnnotation {
                    reading.append(ch)
                }
                i = token.index(after: i)
            }
        }

        // Pure-kana tokens have no annotation; their reading is left empty.
        return (surface, hasAnnotation ? reading : "")
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
