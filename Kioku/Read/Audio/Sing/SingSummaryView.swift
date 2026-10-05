import SwiftUI

// The sheet Sing mode shows when the singer taps Stop: how many of the graded words were heard,
// then each missed word once (in song order). Tapping a missed word opens its dictionary entry,
// where it can be saved; nothing is saved or reviewed automatically.
struct SingSummaryView: View {
    let heardCount: Int
    let gradedCount: Int
    // Missed words in song order, one per distinct surface.
    let missedWords: [SingMissedWord]
    let onLookUp: (Int) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(heardCount) of \(gradedCount)")
                            .scaledFont(size: 34, weight: .bold)
                        Text("words sung")
                            .scaledFont(size: 15)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if missedWords.isEmpty == false {
                    Section("Missed") {
                        ForEach(missedWords, id: \.location) { word in
                            Button {
                                onLookUp(word.location)
                            } label: {
                                HStack {
                                    Text(word.surface)
                                        .scaledFont(size: 17)
                                        .foregroundStyle(Color(.systemRed))
                                    Spacer()
                                    Image(systemName: "book")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// One missed word in the Sing summary: where it sits in the note, and how it's written there.
struct SingMissedWord {
    let location: Int
    let surface: String
}
