import SwiftUI

// Renders the first-visit tour over the whole app window: the screen dimmed except for a rounded
// cutout around the current target, ringed in the accent color, and an accent-filled callout card (title
// and close ✕, message, step count, back/next arrows) with
// an arrow pointing at the cutout. The card goes below the target when there's more room
// there, above otherwise; a target taking up most of the screen (the Read text) gets the card
// inside its lower edge, with no arrow. Tapping the card or the dimmed area advances; the last
// tap ends the tour.
struct TourOverlay: View {
    @ObservedObject private var coordinator = TourCoordinator.shared

    private let cutoutPadding: CGFloat = 6
    private let arrowSize = CGSize(width: 24, height: 12)
    // Room between the cutout and the arrow tip, so the arrow doesn't sit on the highlight ring.
    private let arrowGap: CGFloat = 8
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
                    TourHighlightRing(cornerRadius: cornerRadius(for: cutout))
                        .frame(width: cutout.width, height: cutout.height)
                        .offset(x: cutout.minX, y: cutout.minY)
                        // Restarts the pulse on each step rather than carrying it between targets.
                        .id(step.target)
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
        let radius = cornerRadius(for: cutout)
        return Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRoundedRect(in: cutout, cornerSize: CGSize(width: radius, height: radius))
        }
        .fill(Color.black.opacity(0.72), style: FillStyle(eoFill: true))
        .contentShape(Rectangle())
        .onTapGesture { coordinator.advance() }
        .accessibilityHidden(true)
    }

    // Fully rounded ends for small controls (round buttons stay round), a fixed radius for big areas.
    private func cornerRadius(for cutout: CGRect) -> CGFloat {
        let half = min(cutout.height, cutout.width) / 2
        return half > 22 ? 14 : half
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
            case .below: -(cutout.maxY + arrowGap)
            case .above: -(cutout.minY - arrowGap - dimensions.height)
            case .inside: -(cutout.maxY - edgeMargin - dimensions.height)
            }
        }
        .alignmentGuide(.leading) { _ in -cardX }
    }

    // The arrow segment, offset horizontally to sit under (or over) the target.
    private func arrow(flipped: Bool, x: CGFloat) -> some View {
        TourCalloutArrow()
            .fill(Color.accentColor)
            .frame(width: arrowSize.width, height: arrowSize.height)
            .rotationEffect(flipped ? .degrees(180) : .zero)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: x)
    }

    // Title with a small ✕ that ends the tour, message, progress and back/next arrows. The whole
    // card also advances; its buttons take their own taps first.
    private func card(for step: TourStep) -> some View {
        let isLast = coordinator.stepIndex >= coordinator.stepCount - 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(step.title)
                    .font(.title3.bold())
                Spacer()
                Button {
                    coordinator.finish()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Tour")
            }
            Text(step.message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if coordinator.stepCount > 1 {
                    Text("\(coordinator.stepIndex + 1) of \(coordinator.stepCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                arrowButton("chevron.left", label: "Previous") { coordinator.goBack() }
                    .opacity(coordinator.canGoBack ? 1 : 0.35)
                    .disabled(coordinator.canGoBack == false)
                arrowButton(isLast ? "checkmark" : "chevron.right", label: isLast ? "Done" : "Next") {
                    coordinator.advance()
                }
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { coordinator.advance() }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(named: isLast ? "Done" : "Next") { coordinator.advance() }
    }

    // One of the card's back/next controls: a white symbol in a faint circle, sized for a thumb.
    private func arrowButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.2)))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}
