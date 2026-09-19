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

// Describes the outcome of validating and staging an LLM correction against the view state.
// Nothing is written to the document here — see ReadView+LLMCorrection's
// stageLLMCorrectionResponse / applyPendingSegmentation.
enum LLMCorrectionResult {
    // Corrections staged as a pending proposal; human-readable diff lines describing what
    // would change.
    // changedLocations: all proposed UTF-16 segment start locations, keyed to the segments as
    // they currently render (for UI highlighting and tap targeting).
    // changedReadingLocations: subset where only the furigana reading would change (surface
    // unchanged).
    // changesByLocation: human-readable description of each proposed change, keyed by location.
    case applied(diff: [String], changedLocations: Set<Int>, changedReadingLocations: Set<Int>, changesByLocation: [Int: String])
    // The LLM response surfaces did not concatenate to the original text.
    case surfaceMismatch(String)
    // Network or JSON parsing error from the API call.
    case networkError(String)
    // The LLM returned a response body that could not be decoded as the expected schema.
    case decodingError(String)
}
