import SwiftUI
import WebKit

// Hosts a YouTubePlayerController's web view in SwiftUI. Renders only the video surface; the
// controller owns all behavior, so the representable is a thin pass-through.
struct YouTubePlayerView: UIViewRepresentable {
    let controller: YouTubePlayerController

    // Hands the controller's already-built web view to SwiftUI.
    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    // Nothing to update: the web view is driven by the controller, not by SwiftUI state.
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
