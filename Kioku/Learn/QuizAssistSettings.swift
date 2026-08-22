import Foundation

// Whether the Learn tab may use the on-device model to improve its questions. Separate from the
// LLM provider setting in AI Correction: that one is about segmenting text and can be pointed at a
// paid remote API, whereas this is on-device only and runs unattended while someone is mid-quiz —
// not a thing to turn on by way of a setting they made for a different feature.
//
// Keyed and defaulted here rather than at each @AppStorage so reader and writer can't disagree
// about the default, the same reason LearnedSettings exists.
nonisolated enum QuizAssistSettings {
    // Lets Multiple Choice ask Apple Intelligence to judge and rewrite its answer options.
    static let smarterOptionsKey = "kioku.learn.smarterOptions"
    // On where it's available: the pass runs in the background, costs nothing but on-device
    // compute, and can only ever replace weak options with better ones — a failed or slow model
    // leaves the question exactly as the heuristic built it.
    static let defaultSmarterOptions = true
}
