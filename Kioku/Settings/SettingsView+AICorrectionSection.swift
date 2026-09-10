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
                // Apple Intelligence rows are hidden when their backing model isn't available —
                // both availability checks report live runtime state, so the picker reflects
                // what would actually work rather than listing an option that always errors.
                // On-device and Cloud/Cloud Pro are independent checks: a device can have one
                // without the other (e.g. Apple Intelligence enabled but offline, or an iOS 27
                // Private Cloud Compute entitlement without on-device support).
                Picker("Provider", selection: $llmProviderRaw) {
                    ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                        if isProviderSelectable(provider) {
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                }

                // Each key field only appears while its provider is selected — showing both
                // regardless of the picker just clutters the form with irrelevant fields.
                // Edits write through to the Keychain; nothing secret touches UserDefaults.
                if (LLMProvider(rawValue: llmProviderRaw) ?? .none) == .openAI {
                    SecureField("OpenAI API Key", text: $openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: openAIKey) {
                            LLMSettings.setAPIKey(openAIKey, for: .openAI)
                            llmKeysRevision += 1
                        }
                }
                if (LLMProvider(rawValue: llmProviderRaw) ?? .none) == .claude {
                    SecureField("Claude API Key", text: $claudeKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: claudeKey) {
                            LLMSettings.setAPIKey(claudeKey, for: .claude)
                            llmKeysRevision += 1
                        }
                }

                // Web-search grounding for songs. Hidden for every Apple Intelligence variant —
                // on-device is offline-only, and Foundation Models has no Apple-provided
                // web-search tool for Cloud/Cloud Pro to use either. When on, Claude gets the
                // server-side web_search tool; OpenAI swaps to gpt-5-search-api. Cost
                // increases per call.
                if (LLMProvider(rawValue: llmProviderRaw) ?? .none).isAppleIntelligence == false {
                    Toggle("Web Search Grounding", isOn: $useWebSearch)
                }
            }

            // Lower temperature = more deterministic output; higher = more varied corrections.
            // OpenAI only — current-generation Claude models reject the `temperature`
            // parameter outright, so this has no effect when Claude is the active provider.
            if (LLMProvider(rawValue: llmProviderRaw) ?? .none) != .claude {
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
            }
        } header: {
            Text("AI Correction")
        }
    }

    // Whether a provider row should appear in the picker at all — true for every
    // non-Apple-Intelligence provider (key entry handles their own availability), and gated on
    // the matching live availability check for the three Apple Intelligence variants.
    private func isProviderSelectable(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .appleIntelligence:
            return AppleIntelligenceAvailability.isAvailable
        case .appleIntelligenceCloud, .appleIntelligenceCloudPro:
            return AppleIntelligenceCloudAvailability.isAvailable
        case .none, .openAI, .claude:
            return true
        }
    }
}
