import Foundation

// Response value built by route handlers and serialized by KiokuBridgeServer.
// Handlers never touch the socket directly — they return one of these.
struct BridgeHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    // Returns 200 with a JSON-encoded body, falling back to 500 on encoding failure.
    static func json<T: Encodable>(_ payload: T, status: Int = 200) -> BridgeHTTPResponse {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            return BridgeHTTPResponse(
                status: status,
                headers: ["Content-Type": "application/json; charset=utf-8"],
                body: data
            )
        } catch {
            return error500(message: "encode failed: \(error.localizedDescription)")
        }
    }

    // Returns a structured error envelope so MCP-side handlers can surface a useful message.
    static func error(status: Int, code: String, message: String) -> BridgeHTTPResponse {
        let envelope = ErrorEnvelope(error: ErrorEnvelopeBody(code: code, message: message))
        return json(envelope, status: status)
    }

    // Returns a 204 No Content response used by DELETE handlers.
    static func noContent() -> BridgeHTTPResponse {
        BridgeHTTPResponse(status: 204, headers: [:], body: Data())
    }

    // Returns a 500 Internal Server Error with a structured payload.
    static func error500(message: String) -> BridgeHTTPResponse {
        error(status: 500, code: "internal_error", message: message)
    }
}

// JSON shape returned for any non-2xx response.
struct ErrorEnvelope: Encodable {
    let error: ErrorEnvelopeBody
}

struct ErrorEnvelopeBody: Encodable {
    let code: String
    let message: String
}
