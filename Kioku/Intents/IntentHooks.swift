import SwiftUI

// Attaches App Intent handling to ContentView as one modifier: it performs whatever request an
// intent left on IntentRouter, both at appearance (a cold launch from Siri raises the request
// before ContentView exists) and whenever a new one arrives. A modifier keeps ContentView's long
// modifier chain within what the type-checker can resolve.
struct IntentHooks: ViewModifier {
    @ObservedObject private var router = IntentRouter.shared
    let perform: (IntentRequest) -> Void

    init(perform: @escaping (IntentRequest) -> Void) {
        self.perform = perform
    }

    // Wraps the content with the appear and change triggers.
    func body(content: Content) -> some View {
        content
            .onAppear { drain() }
            .onChange(of: router.pending) { _, _ in drain() }
    }

    // Performs the pending request, if any, exactly once.
    private func drain() {
        guard let request = router.consume() else { return }
        perform(request)
    }
}
