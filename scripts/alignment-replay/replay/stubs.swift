import Foundation

// Stands in for the model download CTCEmissions.loadModel reaches for; the replay never runs the model.
enum HubertPhonemeModelStore {
    // Never called by the replay; present so CTCEmissions.swift compiles without the model plumbing.
    static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL { throw CancellationError() }
}
