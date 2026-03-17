import SwiftUI

// Presents a raw SRT text editor for the subtitle cues attached to a note.
// On save the text is re-parsed and the updated cues are persisted via NoteAudioStore.
struct SubtitleEditorSheet: View {
    var attachmentID: UUID
    var initialCues: [SubtitleCue]
    // Called with the newly parsed cues after a successful save.
    var onSave: ([SubtitleCue]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var srtText = ""
    @State private var parseError = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $srtText)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 8)
                .navigationTitle("Edit Subtitles")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { performSave() }
                    }
                }
                .alert("Parse Error", isPresented: parseErrorPresented) {
                    Button("OK", role: .cancel) { parseError = "" }
                } message: {
                    Text(parseError)
                }
        }
        .onAppear {
            // Reconstruct the SRT text from stored cues so the user sees the current state.
            srtText = SubtitleParser.formatSRT(from: initialCues)
        }
    }

    // Binds the parse-error alert to whether there is currently a failure message.
    private var parseErrorPresented: Binding<Bool> {
        Binding(
            get: { parseError.isEmpty == false },
            set: { if !$0 { parseError = "" } }
        )
    }

    // Re-parses the edited SRT text, saves the cues to disk, and notifies the caller.
    private func performSave() {
        let newCues = SubtitleParser.parse(srtText)
        guard newCues.isEmpty == false else {
            parseError = "No valid subtitle cues found. Check the format and try again."
            return
        }

        do {
            try NoteAudioStore.shared.saveCues(newCues, attachmentID: attachmentID)
            onSave(newCues)
            dismiss()
        } catch {
            parseError = error.localizedDescription
        }
    }
}
