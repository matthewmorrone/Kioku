import SwiftUI

// Runs the first-visit tours. Tagged views report their window frames here; ContentView asks it
// to start a tab's tour when that tab appears; TourOverlay renders whichever step is current.
// One shared instance, like WordOfTheDayNavigation, so `.tourTarget` can report frames from
// anywhere in the hierarchy (toolbars included) without threading an environment object.
@MainActor
final class TourCoordinator: ObservableObject {
    static let shared = TourCoordinator()

    // The tour being shown and the step within it; nil when no tour is running.
    @Published private(set) var activeTab: ContentTab?
    @Published private(set) var stepIndex = 0
    // Frame of the current step's target in window coordinates. Published separately from the
    // full frame table so scrolling a tagged view only redraws the overlay while it's that view's turn.
    @Published private(set) var currentTargetFrame: CGRect?

    private var framesByTarget: [TourTargetID: CGRect] = [:]
    private var pendingStart: Task<Void, Never>?
    private let defaults: UserDefaults

    // Takes the defaults store so the seen flags live with the app's other preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // The step on screen, if a tour is running.
    var currentStep: TourStep? {
        guard let activeTab else { return nil }
        let steps = TourCatalog.steps(for: activeTab)
        return steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    // Step count of the running tour, for the "2 of 5" label.
    var stepCount: Int {
        activeTab.map { TourCatalog.steps(for: $0).count } ?? 0
    }

    // Records where a tagged view sits on screen; nil when it leaves the hierarchy.
    func report(_ frame: CGRect?, for target: TourTargetID) {
        framesByTarget[target] = frame
        if currentStep?.target == target {
            currentTargetFrame = frame
        }
    }

    // Starts the tab's tour unless it has been seen. Waits a moment first so the tab's controls
    // have laid out and reported their frames, and drops the start if the user moves on meanwhile.
    func startIfUnseen(_ tab: ContentTab) {
        pendingStart?.cancel()
        guard activeTab == nil,
              TourCatalog.steps(for: tab).isEmpty == false,
              defaults.bool(forKey: TourCatalog.seenKey(for: tab)) == false else { return }
        pendingStart = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard Task.isCancelled == false, let self, self.activeTab == nil else { return }
            self.activeTab = tab
            self.stepIndex = -1
            self.advance()
        }
    }

    // Abandons a tour that hasn't appeared yet, when the user switches tabs during the delay.
    func cancelPendingStart() {
        pendingStart?.cancel()
        pendingStart = nil
    }

    // Moves to the next step whose target is on screen. A control that isn't showing (a button
    // hidden in this state) is skipped rather than pointed at empty space; past the last step the
    // tour ends.
    func advance() {
        guard let activeTab else { return }
        let steps = TourCatalog.steps(for: activeTab)
        var next = stepIndex + 1
        while next < steps.count, isVisible(steps[next].target) == false {
            next += 1
        }
        guard next < steps.count else {
            finish()
            return
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            stepIndex = next
            currentTargetFrame = framesByTarget[steps[next].target]
        }
    }

    // Ends the running tour and marks its tab seen, whether it was completed or skipped.
    func finish() {
        guard let activeTab else { return }
        defaults.set(true, forKey: TourCatalog.seenKey(for: activeTab))
        withAnimation(.easeOut(duration: 0.25)) {
            self.activeTab = nil
            stepIndex = 0
            currentTargetFrame = nil
        }
    }

    // Clears every tab's seen flag so each tour shows again on that tab's next visit (Settings'
    // Replay Tours).
    func resetAll() {
        for tab in TourCatalog.touredTabs {
            defaults.removeObject(forKey: TourCatalog.seenKey(for: tab))
        }
    }

    // A target counts as on screen when it has reported a frame with some size.
    private func isVisible(_ target: TourTargetID) -> Bool {
        guard let frame = framesByTarget[target] else { return false }
        return frame.width > 0 && frame.height > 0
    }
}
