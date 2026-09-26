import Foundation

// Stands in for the model download MMSEmissions.loadModel reaches for; the replay never runs the model.
enum MMSModelStore {
    // Never called by the replay; present so MMSEmissions.swift compiles without the model plumbing.
    static func ensureModel(onStage: (@Sendable (String) -> Void)? = nil) async throws -> URL { throw CancellationError() }
}
