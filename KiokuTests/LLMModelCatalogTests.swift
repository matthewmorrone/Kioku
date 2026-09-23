import XCTest
@testable import Kioku

// Characterizes the OpenAI side of the Settings model catalog: every offered model stays under a
// cent per typical breakdown.
@MainActor
final class LLMModelCatalogTests: XCTestCase {
    // The OpenAI picker only offers models under a cent per breakdown.
    func testOpenAIModelsAreUnderACentPerBreakdown() {
        for option in LLMModelCatalog.openAI {
            XCTAssertLessThan(LLMModelCatalog.breakdownCostCents(for: option), 1, option.id)
        }
    }
}
