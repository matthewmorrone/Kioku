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
    // True when Foundation Models is present, the OS supports the server-side model (iOS 27+), and
    // PrivateCloudComputeLanguageModel itself reports ready — which also folds in network
    // reachability and per-user quota/service state.
    //
    // `compiler(>=6.4)` gates the PCC symbols: PrivateCloudComputeLanguageModel / ContextOptions
    // are not declared in the Xcode 26.5 SDK CI builds with (Swift 6.3), while FoundationModels
    // itself is, so `canImport(FoundationModels)` alone isn't enough. Xcode 27's Swift 6.4 declares
    // them, so this turns on automatically with a new enough toolchain.
    //
    // Private Cloud Compute also needs the managed entitlement
    // com.apple.developer.private-cloud-compute, which Apple grants per request
    // (https://developer.apple.com/contact/request/private-cloud-compute/). The framework's own
    // availability check does NOT fold that in: without the entitlement it reports available and
    // the first request dies with an uncatchable "Missing entitlement" fatal error
    // (console-confirmed 2026-09-13, commit 8c56630). Flip this to true only once the entitlement
    // is granted and added to Kioku.entitlements.
    static let hasEntitlement = false

    static var isAvailable: Bool {
        guard hasEntitlement else { return false }
        #if canImport(FoundationModels) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        #endif
        return false
    }
}
