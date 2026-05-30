import Foundation

// One parsed HTTP/1.1 request received over the bridge's NWConnection.
// Held as a value type so handlers can pass slices around without retaining socket buffers.
struct BridgeHTTPRequest {
    var method: String
    var path: String
    // Decoded query items, as parsed from the request line. Empty when no query string.
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    // Lower-cased header lookup used by handlers and the auth check.
    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    // Decodes the request body as JSON into a typed value, returning nil when the body is empty.
    func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T? {
        guard body.isEmpty == false else { return nil }
        return try JSONDecoder().decode(type, from: body)
    }
}
