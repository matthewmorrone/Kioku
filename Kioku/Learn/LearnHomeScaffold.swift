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
            // Bound through `Int?` rather than `Int` so clearing the field is a value the binding
            // can represent. Against a non-optional Int an empty field simply fails to parse and
            // snaps back to the previous number, which made the advertised "blank means all"
            // impossible to actually enter.
            TextField("All", value: optionalCount, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
                .focused($focused)
        }
        // The field is only as wide as the digits in it, so without this the tap target is a couple
        // of characters at the far edge of the row and the number reads as static text.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }

    // Bridges the stored "0 means no limit" convention to the empty field that expresses it.
    private var optionalCount: Binding<Int?> {
        Binding(
            get: { count > 0 ? count : nil },
            set: { count = $0 ?? 0 }
        )
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
