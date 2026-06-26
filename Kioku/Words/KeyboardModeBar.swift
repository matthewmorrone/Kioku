import SwiftUI

// Persistent toggle row that lives above whichever input view is active (system keyboard,
// radical picker, or handwriting canvas). Three buttons on the left select the input mode for
// the JapaneseInputTextField that owns this bar; the active mode renders highlighted, like the
// emoji toggle on Apple's system keyboard. Two action buttons on the right edit the destination
// text (backspace one character, clear all) — they work the same regardless of which input mode
// is active. Stateless: takes the current mode as a plain value and reports interactions via the
// closures; the host (a UIHostingController in JapaneseInputTextField's Coordinator) rebuilds
// rootView when state changes.
struct KeyboardModeBar: View {
    let mode: JapaneseInputMode
    let onSelect: (JapaneseInputMode) -> Void
    let onBackspace: () -> Void
    let onReset: () -> Void
    let onClear: () -> Void
    // Optional override the host can wire into a barTintColor-style accent — defaults to system
    // accent so the bar inherits the app's theme without per-call configuration.
    var accent: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            modeButton(
                .radical,
                label: { Text("部").font(.title3.weight(.medium)) },
                accessibility: "Radical input"
            )
            modeButton(
                .handwriting,
                label: { Image(systemName: "hand.point.up.left").font(.system(size: 18, weight: .medium)) },
                accessibility: "Handwriting input"
            )
            modeButton(
                .keyboard,
                label: { Image(systemName: "keyboard").font(.system(size: 18, weight: .medium)) },
                accessibility: "System keyboard"
            )
            Spacer(minLength: 0)
            actionButton(
                systemImage: "arrow.counterclockwise",
                accessibility: "Reset current input",
                action: onReset
            )
            actionButton(
                systemImage: "delete.left",
                accessibility: "Backspace",
                action: onBackspace
            )
            actionButton(
                systemImage: "trash",
                accessibility: "Clear search text",
                action: onClear
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    // Renders an edit action (backspace / clear) on the right of the bar. Same visual size as
    // the mode toggles for a balanced row, but always non-highlighted — they're transient taps,
    // not selections.
    @ViewBuilder
    private func actionButton(
        systemImage: String,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 32)
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    // Renders one mode toggle; selecting an already-active mode is a no-op (the binding
    // assignment trivially repeats and reloadInputViews has nothing to swap).
    @ViewBuilder
    private func modeButton<L: View>(
        _ target: JapaneseInputMode,
        @ViewBuilder label: () -> L,
        accessibility: String
    ) -> some View {
        let isActive = (mode == target)
        Button {
            if mode != target { onSelect(target) }
        } label: {
            label()
                .frame(width: 40, height: 32)
                .foregroundStyle(isActive ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// Input modes for the persistent toggle bar. Defined here (not inside JapaneseInputTextField)
// so the bar can render in previews and tests without instantiating the UIKit bridge.
enum JapaneseInputMode: Hashable {
    case keyboard
    case radical
    case handwriting
}
