import XCTest
@testable import Kioku

// Characterizes ClaudeRequestParameters: effort-capable models get low effort plus reasoning
// headroom so a breakdown isn't swallowed by default-effort reasoning; Haiku keeps the plain cap.
@MainActor
final class ClaudeRequestParametersTests: XCTestCase {

    // Sonnet 5: low effort, cap raised by the headroom.
    func testEffortCapableModelGetsLowEffortAndHeadroom() {
        var body: [String: Any] = [:]
        ClaudeRequestParameters.apply(to: &body, model: "claude-sonnet-5", maxTokens: 8192)
        XCTAssertEqual(body["max_tokens"] as? Int, 8192 + ClaudeRequestParameters.reasoningHeadroomTokens)
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
    }

    // Haiku 4.5 rejects effort: plain cap, no output_config.
    func testHaikuKeepsPlainShape() {
        var body: [String: Any] = [:]
        ClaudeRequestParameters.apply(to: &body, model: "claude-haiku-4-5", maxTokens: 8192)
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertNil(body["output_config"])
    }
}
