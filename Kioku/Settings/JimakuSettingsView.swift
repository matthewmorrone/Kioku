import SwiftUI

// Credentials form for Jimaku (Feature B): a single API-key field bound directly to the UserDefaults
// key JimakuSettings reads, via @AppStorage. Reachable from the search screen's toolbar; can also be
// linked from the main SettingsView.
struct JimakuSettingsView: View {
    @AppStorage(JimakuSettings.apiKeyStorageKey) private var apiKey = ""

    var body: some View {
        Form {
            Section {
                TextField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
