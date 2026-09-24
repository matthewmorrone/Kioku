import XCTest
@testable import Kioku

// Characterizes OpenAIRequestParameters: GPT-5
// reasoning models get max_completion_tokens (with reasoning headroom) and low reasoning effort
// and no temperature; older models keep max_tokens and the user's temperature.
@MainActor
final class OpenAIRequestParametersTests: XCTestCase {

    // Builds the parameters a request for `model` would carry.
    private func body(for model: String, temperature: Double? = 0.4) -> [String: Any] {
        var body: [String: Any] = [:]
        OpenAIRequestParameters.apply(to: &body, model: model, maxTokens: 8192, temperature: temperature)
        return body
    }

    // gpt-5 family: completion cap with headroom, low effort, no temperature or max_tokens.
    func testReasoningModelParameters() {
        for model in ["gpt-5", "gpt-5-mini", "gpt-5.6-luna"] {
            let b = body(for: model)
            XCTAssertEqual(b["max_completion_tokens"] as? Int, 8192 + OpenAIRequestParameters.reasoningHeadroomTokens, model)
            XCTAssertEqual(b["reasoning_effort"] as? String, "low", model)
            XCTAssertNil(b["max_tokens"], model)
            XCTAssertNil(b["temperature"], model)
        }
    }

    // gpt-4o / gpt-4.1: unchanged shape.
    func testOlderModelParameters() {
        for model in ["gpt-4o", "gpt-4.1-mini"] {
            let b = body(for: model)
            XCTAssertEqual(b["max_tokens"] as? Int, 8192, model)
            XCTAssertEqual(b["temperature"] as? Double, 0.4, model)
            XCTAssertNil(b["max_completion_tokens"], model)
            XCTAssertNil(b["reasoning_effort"], model)
        }
    }

}
