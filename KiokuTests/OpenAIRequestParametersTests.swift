import XCTest
@testable import Kioku

// Characterizes OpenAIRequestParameters and the Settings model catalog's price labels: GPT-5
// reasoning models get max_completion_tokens (with reasoning headroom) and low reasoning effort
// and no temperature; older models keep max_tokens and the user's temperature; the search model
// keeps the older shape.
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

    // The search model keeps max_tokens; a nil temperature is simply omitted.
    func testSearchModelKeepsOlderShape() {
        let b = body(for: LLMSettings.openAISearchModel, temperature: nil)
        XCTAssertEqual(b["max_tokens"] as? Int, 8192)
        XCTAssertNil(b["temperature"])
        XCTAssertNil(b["reasoning_effort"])
    }

    // Prices show cents only when there are any.
    func testPriceLabels() {
        XCTAssertEqual(LLMModelCatalog.priceLabel(for: LLMModelOption(id: "a", inputPerMillion: 0.25, outputPerMillion: 2)), "$0.25 / $2")
        XCTAssertEqual(LLMModelCatalog.priceLabel(for: LLMModelOption(id: "b", inputPerMillion: 2.5, outputPerMillion: 10)), "$2.50 / $10")
    }

    // Every provider default is offered in its own picker.
    func testDefaultsAreInCatalog() {
        XCTAssertTrue(LLMModelCatalog.openAI.contains { $0.id == LLMSettings.defaultOpenAIModel })
        XCTAssertTrue(LLMModelCatalog.claude.contains { $0.id == LLMSettings.defaultClaudeModel })
    }
}
