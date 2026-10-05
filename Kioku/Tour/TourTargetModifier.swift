import SwiftUI

// Reports the modified view's window frame to TourCoordinator under a tour target ID, so the
// overlay can cut a hole around it. Global coordinates, not anchor preferences: preferences set
// inside a toolbar item never reach the content hierarchy, and half the targets are toolbar buttons.
struct TourTargetModifier: ViewModifier {
    // Nil leaves the view untagged — for list rows where only the first one is a target.
    let target: TourTargetID?

    // Tracks the frame as the view lays out and moves, and withdraws it when the view goes away.
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                guard let target else { return }
                TourCoordinator.shared.report(frame, for: target)
            }
            .onDisappear {
                guard let target else { return }
                TourCoordinator.shared.report(nil, for: target)
            }
    }
}

extension View {
    // Marks this view as something a first-visit tour can point at.
    func tourTarget(_ target: TourTargetID?) -> some View {
        modifier(TourTargetModifier(target: target))
    }
}
