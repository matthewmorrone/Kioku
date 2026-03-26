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
            Form {
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

                Section {
                    Button {
                        guard let id = selectedNoteID else { return }
                        activeNote = notesStore.notes.first { $0.id == id }
                    } label: {
                        Label("Start Cloze", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedNoteID == nil)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        Text("Cloze")
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Cloze")
                }
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
}
