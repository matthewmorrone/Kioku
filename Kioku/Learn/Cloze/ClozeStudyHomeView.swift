import SwiftUI

// Renders the cloze study configuration screen where users pick a note and session options.
// Major sections: mode/blanks/dedup options, note source picker, start button.
struct ClozeStudyHomeView: View {
    @EnvironmentObject private var notesStore: NotesStore

    @State private var mode: ClozeMode = .random
    @State private var blanksPerSentence: Int = 1
    @State private var selectedNoteID: UUID? = nil
    @State private var activeNote: Note? = nil

    @AppStorage("clozeExcludeDuplicateLines") private var excludeDuplicateLines: Bool = true

    var body: some View {
        NavigationStack {
            LearnHomeForm(
                startTitle: "Start Cloze",
                startEnabled: selectedNoteID != nil,
                onStart: { startCloze() }
            ) {
                Section {
                    Picker("Order", selection: $mode) {
                        ForEach(ClozeMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(
                        "Dropdowns per sentence: \(blanksPerSentence)",
                        value: $blanksPerSentence,
                        in: 1...10,
                        step: 1
                    )

                    Toggle("Exclude duplicate lines", isOn: $excludeDuplicateLines)
                }

                Section {
                    if notesStore.notes.isEmpty {
                        Text("Add a note to study.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Note", selection: $selectedNoteID) {
                            Text("Select a note").tag(UUID?.none)
                            ForEach(notesStore.notes) { note in
                                Text(note.title.isEmpty ? "Untitled" : note.title)
                                    .tag(UUID?.some(note.id))
                            }
                        }
                    }
                } header: {
                    Text("Source")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LearnHomeTitle(title: "Cloze", systemImage: "rectangle.and.pencil.and.ellipsis")
            }
            .navigationDestination(item: $activeNote) { note in
                ClozeStudyView(
                    note: note,
                    initialMode: mode,
                    initialBlanksPerSentence: blanksPerSentence,
                    excludeDuplicateLines: excludeDuplicateLines
                )
            }
            .onAppear {
                // Default to the first note so the Start button is enabled immediately.
                if selectedNoteID == nil {
                    selectedNoteID = notesStore.notes.first?.id
                }
            }
        }
    }

    // Resolves the selected note and pushes into the cloze session.
    private func startCloze() {
        guard let id = selectedNoteID else { return }
        activeNote = notesStore.notes.first { $0.id == id }
    }
}
