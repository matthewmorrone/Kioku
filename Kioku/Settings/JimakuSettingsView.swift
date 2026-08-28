import SwiftUI

// Credentials form for Jimaku (Feature B): a single API-key field whose value lives in the
// Keychain via JimakuSettings. @State holds the editing copy; onChange writes through so the
// secret never touches UserDefaults. Reachable from the search screen's toolbar; can also be
// linked from the main SettingsView.
struct JimakuSettingsView: View {
    @State private var apiKey = JimakuSettings.apiKey() ?? ""
    // The key currently persisted in the Keychain. Kept separate from the editing copy so the
    // Confirm button can tell whether there is an unsaved edit and show a saved-state indicator.
    @State private var savedKey = JimakuSettings.apiKey() ?? ""

    // The editing copy with surrounding whitespace removed — pasted keys often carry a trailing
    // newline or space. Comparing and saving the trimmed value keeps both consistent.
    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // True only when the trimmed field differs from what is stored — the sole case where confirming
    // does anything, so it also gates the button's enabled state.
    private var hasUnsavedChange: Bool {
        trimmedKey != savedKey
    }

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { confirmKey() }

                // Explicit confirm: the key is written to the Keychain only on tap (not on every
                // keystroke), so a half-typed key is never persisted, and the label doubles as the
                // "it's saved" signal the write-through version never gave.
                Button {
                    confirmKey()
                } label: {
                    if hasUnsavedChange {
                        Text(savedKey.isEmpty ? "Confirm" : "Update Key")
                    } else if savedKey.isEmpty {
                        Text("No key saved").foregroundStyle(.secondary)
                    } else {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(hasUnsavedChange == false)
            } header: {
                Text("Jimaku")
            }
        }
        .navigationTitle("Jimaku")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Persists the trimmed key to the Keychain and syncs the editing + saved-state copies so the
    // button collapses back to its "Saved" indicator.
    private func confirmKey() {
        guard hasUnsavedChange else { return }
        JimakuSettings.setAPIKey(trimmedKey)
        apiKey = trimmedKey
        savedKey = trimmedKey
    }
}
