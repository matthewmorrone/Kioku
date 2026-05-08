import Foundation

// Minimal HTTP/1.1 request parser sized for the LAN-only MCP bridge.
// Supports plain CRLF framing, Content-Length bodies, and ASCII headers — the only
// shapes the Node MCP server is going to send. Streaming and chunked encoding are
// intentionally not supported; the bridge rejects oversized bodies up front.
enum BridgeHTTPParser {
    // Hard cap on the body length the bridge will accept. Notes are user prose and
    // stay well under this in practice; rejecting anything bigger keeps the parser
    // from buffering arbitrary data on a process the user trusted to host their notes.
    static let maxBodyBytes: Int = 1_048_576

    // Returns the parsed request together with any remaining buffer bytes when the
    // header block is intact and the body has fully arrived. Returns nil when more
    // bytes are needed; throws on malformed wire data so the caller can close the
    // connection rather than wait forever.
    static func parse(_ buffer: Data) throws -> (request: BridgeHTTPRequest, remaining: Data)? {
        guard let headerEndRange = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            // Header block not yet complete; ask for more bytes.
            return nil
        }

        let headerData = buffer[..<headerEndRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw BridgeHTTPParserError.invalidHeaderEncoding
        }

        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            throw BridgeHTTPParserError.malformedRequestLine
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw BridgeHTTPParserError.malformedRequestLine
        }

        let method = String(parts[0])
        let target = String(parts[1])
        // Ignore the HTTP version (parts[2]); we always reply 1.1.

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard line.isEmpty == false else { continue }
            guard let colonIndex = line.firstIndex(of: ":") else {
                throw BridgeHTTPParserError.malformedHeader
            }

            let name = line[..<colonIndex].lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[String(name)] = value
        }

        let bodyStart = headerEndRange.upperBound
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        if contentLength < 0 || contentLength > maxBodyBytes {
            throw BridgeHTTPParserError.bodyTooLarge
        }

        let availableBody = buffer.count - bodyStart
        if availableBody < contentLength {
            // Body still arriving.
            return nil
        }

        let bodyEnd = bodyStart + contentLength
        let body = Data(buffer[bodyStart..<bodyEnd])
        let remaining = bodyEnd < buffer.count ? Data(buffer[bodyEnd...]) : Data()

        let (path, query) = splitTarget(target)
        let request = BridgeHTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
        return (request, remaining)
    }

    // Splits a request target into the path component and a parsed query dictionary.
    private static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let questionMarkIndex = target.firstIndex(of: "?") else {
            return (target, [:])
        }

        let path = String(target[..<questionMarkIndex])
        let queryString = target[target.index(after: questionMarkIndex)...]
        var query: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].removingPercentEncoding ?? String(parts[0])
            let value = parts.count == 2 ? (parts[1].removingPercentEncoding ?? String(parts[1])) : ""
            query[key] = value
        }
        return (path, query)
    }
}

// Distinct error cases so the bridge server can log a precise reason when it closes a connection.
enum BridgeHTTPParserError: Error {
    case malformedRequestLine
    case malformedHeader
    case invalidHeaderEncoding
    case bodyTooLarge
}
