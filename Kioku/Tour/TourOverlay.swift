import SwiftUI

// Renders the first-visit tour over the whole app window: the screen dimmed except for a rounded
// cutout around the current target, and a callout card (title, message, step count, Skip / Next)
// with an arrow pointing at the cutout. The card goes below the target when there's more room
// there, above otherwise; a target taking up most of the screen (the Read text) gets the card
// inside its lower edge, with no arrow. Tapping the dimmed area advances, as Next does.
struct TourOverlay: View {
    @ObservedObject private var coordinator = TourCoordinator.shared

    private let cutoutPadding: CGFloat = 6
    private let arrowSize = CGSize(width: 20, height: 10)
    private let cardWidth: CGFloat = 300
    private let edgeMargin: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            if let step = coordinator.currentStep, let targetFrame = coordinator.currentTargetFrame {
                let origin = proxy.frame(in: .global).origin
                let cutout = targetFrame
                    .offsetBy(dx: -origin.x, dy: -origin.y)
                    .insetBy(dx: -cutoutPadding, dy: -cutoutPadding)
                let placement: TourCalloutPlacement = cutout.height > proxy.size.height * 0.4
                    ? .inside
                    : (cutout.midY < proxy.size.height / 2 ? .below : .above)
                ZStack(alignment: .topLeading) {
                    dimming(around: cutout, in: proxy.size)
                    callout(for: step, pointingAt: cutout, placement: placement, in: proxy.size)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
    }

    // The dark layer with a hole punched around the target. Even-odd fill leaves the hole clear;
    // the whole layer still takes taps, so the highlighted control can't be used mid-tour.
    private func dimming(around cutout: CGRect, in size: CGSize) -> some View {
        let radius = min(cutout.height, cutout.width) / 2 > 22 ? 14 : min(cutout.height, cutout.width) / 2
        return Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: radius, height: radius))
        }
        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
        .contentShape(Rectangle())
        .onTapGesture { coordinator.advance() }
        .accessibilityHidden(true)
    }

    // The card and its arrow, kept inside the screen edges and pointing at the cutout's centre.
    private func callout(for step: TourStep, pointingAt cutout: CGRect, placement: TourCalloutPlacement, in size: CGSize) -> some View {
        let width = min(cardWidth, size.width - edgeMargin * 2)
        let cardX = min(max(cutout.midX - width / 2, edgeMargin), size.width - width - edgeMargin)
        let arrowX = min(max(cutout.midX, cardX + 20), cardX + width - 20) - arrowSize.width / 2
        return VStack(spacing: 0) {
            if placement == .below {
                arrow(flipped: false, x: arrowX - cardX)
            }
            card(for: step)
                .frame(width: width)
            if placement == .above {
                arrow(flipped: true, x: arrowX - cardX)
            }
        }
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        // Alignment guides place the card from its own measured height, which `.offset` can't see.
        .alignmentGuide(.top) { dimensions in
            switch placement {
            case .below: -(cutout.maxY + 4)
            case .above: -(cutout.minY - 4 - dimensions.height)
            case .inside: -(cutout.maxY - edgeMargin - dimensions.height)
            }
        }
        .alignmentGuide(.leading) { _ in -cardX }
    }

    // The arrow segment, offset horizontally to sit under (or over) the target.
    private func arrow(flipped: Bool, x: CGFloat) -> some View {
        TourCalloutArrow()
            .fill(Color(.systemBackground))
            .frame(width: arrowSize.width, height: arrowSize.height)
            .rotationEffect(flipped ? .degrees(180) : .zero)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: x)
    }

    // Title, message, progress and the two buttons.
    private func card(for step: TourStep) -> some View {
        let isLast = coordinator.stepIndex >= coordinator.stepCount - 1
        return VStack(alignment: .leading, spacing: 8) {
            Text(step.title)
                .font(.headline)
            Text(step.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if coordinator.stepCount > 1 {
                    Text("\(coordinator.stepIndex + 1) of \(coordinator.stepCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLast == false {
                    Button("Skip") { coordinator.finish() }
                        .buttonStyle(.borderless)
                }
                Button(isLast ? "Done" : "Next") { coordinator.advance() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}
