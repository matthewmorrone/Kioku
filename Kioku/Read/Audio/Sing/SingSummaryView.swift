import SwiftUI

// The sheet Sing mode shows when the singer taps Stop: how many of the graded words were heard
// (and how strictly), each missed word once (in song order), then the song's earlier sessions.
// Tapping a missed word opens its dictionary entry, where it can be saved; nothing is saved or
// reviewed automatically.
struct SingSummaryView: View {
    let heardCount: Int
    let gradedCount: Int
    let strictness: SingStrictness
    // Missed words in song order, one per distinct surface.
    let missedWords: [SingMissedWord]
    // The song's sessions, newest first (this one included once saved).
    let history: [SingSessionRecord]
    let onLookUp: (Int) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(heardCount) of \(gradedCount)")
                            .scaledFont(size: 34, weight: .bold)
                        Text("words sung · \(strictness.label)")
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
                if history.isEmpty == false {
                    Section("Sessions") {
                        ForEach(history, id: \.date) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.date.formatted(date: .abbreviated, time: .shortened))
                                        .scaledFont(size: 15)
                                    Text("\(session.scope) · \(session.strictness.label)")
                                        .scaledFont(size: 12)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(session.heardCount)/\(session.gradedCount)")
                                    .scaledFont(size: 15, weight: .semibold)
                                    .monospacedDigit()
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
