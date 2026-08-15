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
        // Kept for any text entry a host adds to the form; the shared controls are all menus.
        .scrollDismissesKeyboard(.interactively)
        .washiBackground()
    }
}

// The standard "how long should this session be?" control for the Learn start screens and the
// Coverage launch sheet. A menu of preset sizes rather than a text field: the values people
// actually pick are a short list, and the free-text version was a keypad-only field whose tap
// target was the width of its own digits. 0 means "no limit" and shows as All.
struct LearnCountPicker: View {
    let label: String
    @Binding var count: Int

    // Session sizes worth offering. Small steps near the bottom, where the difference between 10
    // and 15 questions is felt, and coarser above.
    private static let choices = [5, 10, 15, 20, 25, 30, 50, 100]

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Menu(count > 0 ? "\(count)" : "All") {
                Button { count = 0 } label: {
                    if count == 0 {
                        Label("All", systemImage: "checkmark")
                    } else {
                        Text("All")
                    }
                }
                Divider()
                ForEach(Self.choices, id: \.self) { choice in
                    Button { count = choice } label: {
                        if count == choice {
                            Label("\(choice)", systemImage: "checkmark")
                        } else {
                            Text("\(choice)")
                        }
                    }
                }
                // A count restored from a previous build (or a Coverage launch) that isn't one of
                // the presets stays selectable rather than silently vanishing from its own menu.
                if count > 0, Self.choices.contains(count) == false {
                    Divider()
                    Button { } label: { Label("\(count)", systemImage: "checkmark") }
                }
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
