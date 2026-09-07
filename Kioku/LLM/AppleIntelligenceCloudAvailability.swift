import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Availability check for Apple Intelligence's server-side model (Private Cloud Compute),
// mirroring AppleIntelligenceAvailability's on-device check. Kept as a plain, un-gated enum
// (like its on-device counterpart) so call sites outside a FoundationModels-aware file — Settings,
// LLMSettings — can check it without their own #if/availability boilerplate. Split into its own
// file (rather than living alongside AppleIntelligenceCloudClient) per this repo's Type
// Organization rule: any type with logic (here, the isAvailable computed property) gets its own
// file named after the type.
enum AppleIntelligenceCloudAvailability {
    // True when Foundation Models is present, the OS supports the server-side model (iOS 27+),
    // and PrivateCloudComputeLanguageModel itself reports ready — which also folds in the
    // com.apple.developer.private-cloud-compute entitlement, network reachability, and per-user
    // quota/service state. NOTE: the exact availability surface (a plain `isAvailable` Bool vs.
    // a richer `availability` enum) is unverified against a real iOS 27 SDK — this skill's
    // research found `isAvailable` cited but could not compile-check it. If this doesn't build,
    // check PrivateCloudComputeLanguageModel's actual API first.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }
}
