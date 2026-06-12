import XCTest
@testable import Kioku

// Pins the bridge parser's denial-of-service bounds: header blocks and bodies are
// both capped, and the headers-only peek used for early auth reads what the full
// parse reads.
@MainActor
final class BridgeHTTPParserTests: XCTestCase {
    // A complete small request parses with its headers, body, and query intact.
    func testParsesCompleteRequest() throws {
        let raw = Data("POST /notes?id=abc HTTP/1.1\r\nAuthorization: Bearer t\r\nContent-Length: 2\r\n\r\nhi".utf8)

        let parsed = try XCTUnwrap(BridgeHTTPParser.parse(raw))
        XCTAssertEqual(parsed.request.method, "POST")
        XCTAssertEqual(parsed.request.path, "/notes")
        XCTAssertEqual(parsed.request.query["id"], "abc")
        XCTAssertEqual(parsed.request.header("authorization"), "Bearer t")
        XCTAssertEqual(parsed.request.body, Data("hi".utf8))
    }

    // A header block that never terminates must be rejected once it exceeds the cap,
    // not buffered forever.
    func testRejectsUnterminatedOversizedHeaderBlock() {
        var raw = Data("GET / HTTP/1.1\r\n".utf8)
        raw.append(Data(repeating: UInt8(ascii: "a"), count: BridgeHTTPParser.maxHeaderBytes + 1))

        XCTAssertThrowsError(try BridgeHTTPParser.parse(raw))
    }

    // A terminated header block over the cap is rejected as well.
    func testRejectsTerminatedOversizedHeaderBlock() {
        var raw = Data("GET / HTTP/1.1\r\nX-Filler: ".utf8)
        raw.append(Data(repeating: UInt8(ascii: "b"), count: BridgeHTTPParser.maxHeaderBytes + 1))
        raw.append(Data("\r\n\r\n".utf8))

        XCTAssertThrowsError(try BridgeHTTPParser.parse(raw))
    }

    // Declared bodies over the cap are rejected before any buffering decision.
    func testRejectsOversizedDeclaredBody() {
        let raw = Data("POST / HTTP/1.1\r\nContent-Length: \(BridgeHTTPParser.maxBodyBytes + 1)\r\n\r\n".utf8)
        XCTAssertThrowsError(try BridgeHTTPParser.parse(raw))
    }

    // The headers-only peek returns the auth header as soon as the block completes,
    // and nil while bytes are still arriving.
    func testHeaderFieldsPeekForEarlyAuth() {
        let partial = Data("POST / HTTP/1.1\r\nAuthorization: Bearer t\r\n".utf8)
        XCTAssertNil(BridgeHTTPParser.headerFields(partial))

        let complete = partial + Data("\r\n".utf8)
        XCTAssertEqual(BridgeHTTPParser.headerFields(complete)?["authorization"], "Bearer t")
    }
}
