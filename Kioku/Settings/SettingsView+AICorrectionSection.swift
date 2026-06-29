import SwiftUI

// Section for the AI correction provider configuration, extracted from
// SettingsView to keep the parent file under the project's 1000-line
// invariant. All @AppStorage / @State the section uses live on SettingsView;
// this extension just shapes the UI.
extension SettingsView {
    // Renders the provider toggle, picker, key fields, web-search toggle,
    // and temperature slider as one Form section.
    @ViewBuilder
    var aiCorrectionSection: some View {
        Section {
            Toggle("Use LLM API", isOn: $useLLM)

            if useLLM {
                // Apple Intelligence row is hidden on devices where Foundation
                // Models isn't available — the framework reports availability at
                // runtime, so the picker reflects the live state rather than
                // listing an option that would always error.
                Picker("Provider", selection: $llmProviderRaw) {
                    ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                        if provider != .appleIntelligence || AppleIntelligenceAvailability.isAvailable {
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                }

                // Key entry rows are always visible so both keys can be saved independently.
                // Edits write through to the Keychain; nothing secret touches UserDefaults.
                SecureField("OpenAI API Key", text: $openAIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: openAIKey) {
                        LLMSettings.setAPIKey(openAIKey, for: .openAI)
                        llmKeysRevision += 1
                    }
                SecureField("Claude API Key", text: $claudeKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: claudeKey) {
                        LLMSettings.setAPIKey(claudeKey, for: .claude)
                        llmKeysRevision += 1
                    }

                // Web-search grounding for songs. Hidden when the provider can't
                // use it (Apple Intelligence is offline-only). When on, Claude
                // gets the server-side web_search tool; OpenAI swaps to
                // gpt-4o-search-preview. Cost increases per call.
                if (LLMProvider(rawValue: llmProviderRaw) ?? .none) != .appleIntelligence {
                    Toggle(isOn: $useWebSearch) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Web Search Grounding")
                            Text("Lets the model look up canonical lyrics for songs — useful for gikun/ateji readings JMdict doesn't carry. Adds per-call cost.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Lower temperature = more deterministic output; higher = more varied corrections.
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.2f", temperature))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $temperature, in: 0.0...1.0, step: 0.05)
            }
        } header: {
            Text("AI Correction")
        }
    }
}
