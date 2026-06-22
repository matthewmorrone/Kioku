import SwiftUI

// Shared chrome for the three Learn-tab start screens (Flashcards, Multiple Choice, Cloze) so they
// present a consistent layout: an options Form capped by a single prominent Start button. The host
// keeps ownership of the NavigationStack and toolbar — Flashcards and Multiple Choice share that
// stack with their in-place session state — so this scaffold deliberately covers only the Form
// body and the trailing Start section. Pair it with `LearnHomeTitle` for the matching toolbar.
struct LearnHomeForm<Content: View>: View {
    let startTitle: String
    var startSystemImage: String = "play.fill"
    let startEnabled: Bool
    let onStart: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
            Section {
                Button(action: onStart) {
                    Label(startTitle, systemImage: startSystemImage)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(startEnabled == false)
            }
        }
        // Swipe down over any start form to dismiss a numeric keyboard (the count field has no
        // return key); `LearnCountField` supplies a Done button as the explicit affordance.
        .scrollDismissesKeyboard(.interactively)
        .washiBackground()
    }
}

// A standard "limit the session size" numeric field for the Learn start screens. Owns its own
// focus so it can offer a keyboard Done button (the numberPad has no return key); 0 / blank means
// "no limit". Both Flashcards and Multiple Choice use it so the control reads identically.
struct LearnCountField: View {
    let label: String
    @Binding var count: Int
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("All", value: $count, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
                .focused($focused)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }
}

// The standard Learn-tab principal toolbar title: an SF Symbol plus the mode name, styled
// identically across the three start screens. Drop into any `.toolbar { }` builder, alongside
// other toolbar items (e.g. a session's End/Shuffle controls) as needed.
struct LearnHomeTitle: ToolbarContent {
    let title: String
    let systemImage: String

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
        }
    }
}
