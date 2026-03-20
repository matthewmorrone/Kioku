import Foundation

// Represents a single segment surface paired with its furigana reading.
// Surfaces must concatenate exactly to the original note text.
struct LLMSegmentEntry: Codable {
    // The surface form as it appears in the note text.
    var surface: String
    // The kana reading for the surface. Empty string means no furigana (kana-only or punctuation).
    var reading: String
}

// The structured response the LLM is expected to return.
// Decoding fails gracefully if the model omits or misspells the key.
struct LLMCorrectionResponse: Codable {
    var segments: [LLMSegmentEntry]
}

// Describes the outcome of applying an LLM correction to the view state.
enum LLMCorrectionResult {
    // Corrections applied; human-readable diff lines describing what changed.
    case applied(diff: [String])
    // The LLM response surfaces did not concatenate to the original text.
    case surfaceMismatch
    // Network or JSON parsing error from the API call.
    case networkError(String)
    // The LLM returned a response body that could not be decoded as the expected schema.
    case decodingError(String)
}
