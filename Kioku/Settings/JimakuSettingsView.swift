import SwiftUI

// Credentials form for Jimaku (Feature B): a single API-key field whose value lives in the
// Keychain via JimakuSettings. @State holds the editing copy; onChange writes through so the
// secret never touches UserDefaults. Reachable from the search screen's toolbar; can also be
// linked from the main SettingsView.
struct JimakuSettingsView: View {
    @State private var apiKey = JimakuSettings.apiKey() ?? ""

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) {
                        JimakuSettings.setAPIKey(apiKey)
                    }
            } header: {
                Text("Jimaku")
            } footer: {
                Text("Create a free account at jimaku.cc, then copy your API key from Account → API. This single key is all that's needed to search and download.")
            }
        }
        .navigationTitle("Jimaku")
        .navigationBarTitleDisplayMode(.inline)
    }
}
