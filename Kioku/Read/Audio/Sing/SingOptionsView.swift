import SwiftUI

// The Sing options sheet, opened from the gear on the lyrics popup's Sing row. Sections: Reveal
// (whether the words being listened for are hidden while singing) and Strictness (how much of a
// word must be heard), each with a line saying what it does.
struct SingOptionsView: View {
    @Binding var reveal: SingReveal
    @Binding var strictness: SingStrictness
    // True while a session runs: strictness applies from the next start.
    let isStrictnessLocked: Bool
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reveal", selection: $reveal) {
                        ForEach(SingReveal.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Reveal")
                } footer: {
                    Text("Hidden words show as 〇 without furigana until they're graded, or until you stop.")
                }
                Section {
                    Picker("Strictness", selection: $strictness) {
                        ForEach(SingStrictness.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isStrictnessLocked)
                } header: {
                    Text("Strictness")
                } footer: {
                    Text(isStrictnessLocked
                         ? "Applies from the next session."
                         : "How much of each word's vowels and consonants must be heard: a third, half, or three quarters.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
