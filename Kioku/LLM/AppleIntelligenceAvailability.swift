import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Whether the on-device Apple Intelligence model can be used right now. Gates Multiple Choice's
// "Smarter Quiz Options" (AppleIntelligenceDistractorClient) and its Settings toggle.
enum AppleIntelligenceAvailability {
    // Returns true when Foundation Models is present AND the device's system
    // language model reports itself as ready. Reads the framework lazily so
    // the symbol is only touched inside the #available guard.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }
}
