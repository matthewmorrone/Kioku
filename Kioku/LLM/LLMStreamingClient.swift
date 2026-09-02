import Foundation

// Server-sent-events client for the two remote chat providers. Both breakdown services
// (SongBreakdownService, MergedCorrectionBreakdownService) go through here so the progressive
// per-line UI in SongStepperView gets text as the model writes it instead of one blob after a
// 30–180s wait. Each call returns the fully accumulated text (so callers parse exactly what a
// non-streaming request would have returned) and invokes `onDelta` with every text fragment
// as it arrives, on the network task — callers hop to the main actor themselves.
//
// Wire formats handled:
//   - OpenAI chat completions with `stream: true`: `data: {json}` lines whose
//     `choices[0].delta.content` carries the fragment, terminated by `data: [DONE]`.
//   - Anthropic Messages with `stream: true`: `data: {json}` lines where
//     `type == "content_block_delta"` and `delta.type == "text_delta"` carry the fragment;
//     an `error` event surfaces as a thrown networkError.
//
// Errors are thrown as SongBreakdownError since the breakdown flows are the only consumers;
// a non-2xx status reads the whole body first so the message carries the provider's own
// explanation (quota, model, key) rather than a bare status code.
//
// `nonisolated`: the byte loop must run off the main actor (the module defaults to MainActor
// isolation), and every delta callback it makes is @Sendable for the same reason.
nonisolated enum LLMStreamingClient {

    // Streams an OpenAI chat completion. `messages` is the same role/content array a
    // non-streaming call would send; only `stream: true` is added.
    static func streamOpenAI(
        apiKey: String,
        model: String,
        messages: [[String: String]],
        maxTokens: Int,
        temperature: Double,
        urlSession: URLSession,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await consume(request: request, urlSession: urlSession, providerName: "OpenAI") { json in
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { return nil }
            return content
        } onDelta: { onDelta($0) }
    }

    // Streams an Anthropic Messages completion. `system` is passed through verbatim so the
    // caller keeps control of cache_control blocks; only `stream: true` is added.
    static func streamClaude(
        apiKey: String,
        model: String,
        system: [[String: Any]],
        userContent: String,
        maxTokens: Int,
        temperature: Double,
        urlSession: URLSession,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": system,
            "messages": [
                ["role": "user", "content": userContent]
            ],
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await consume(request: request, urlSession: urlSession, providerName: "Claude") { json in
            let type = json["type"] as? String
            if type == "error" {
                let message = (json["error"] as? [String: Any])?["message"] as? String ?? "unknown stream error"
                throw SongBreakdownError.networkError("Claude stream error: \(message)")
            }
            guard type == "content_block_delta",
                  let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return text
        } onDelta: { onDelta($0) }
    }

    // Opens the byte stream, validates the status (draining the body for the error message on
    // failure), then walks SSE lines. `extract` turns one decoded `data:` JSON object into a
    // text fragment (nil = not a text event). Cancellation propagates out of the byte iterator
    // as CancellationError, so a cancelled Task stops reading mid-stream without special-casing.
    private static func consume(
        request: URLRequest,
        urlSession: URLSession,
        providerName: String,
        extract: ([String: Any]) throws -> String?,
        onDelta: (String) -> Void
    ) async throws -> String {
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SongBreakdownError.networkError("\(providerName): non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let body = String(data: errorData, encoding: .utf8) ?? "(unreadable)"
            NSLog("%@", "[LLMStreaming] \(providerName) HTTP \(http.statusCode) body=\(body.prefix(400))")
            throw SongBreakdownError.networkError("\(providerName) HTTP \(http.statusCode): \(body)")
        }

        var accumulated = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // A malformed event line is skipped rather than fatal — the stream's final
                // message_stop / [DONE] still arrives and the accumulated text is what matters.
                continue
            }
            if let fragment = try extract(json), fragment.isEmpty == false {
                accumulated += fragment
                onDelta(fragment)
            }
        }
        guard accumulated.isEmpty == false else {
            throw SongBreakdownError.unexpectedResponseShape("\(providerName) stream ended with no text content")
        }
        return accumulated
    }
}
