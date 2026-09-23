import SwiftUI

// The AI section of Settings, extracted from SettingsView to keep the parent file under the
// project's 1000-line invariant. All @AppStorage / @State it uses live on SettingsView; this
// extension just shapes the UI. On-device Apple Intelligence isn't a picker choice — it's a
// capability the app uses on its own for Correction whenever the toggle is on and the device
// has it (Breakdown can't use it at all). The Provider picker is the shared remote model
// (None / OpenAI / Claude), used for Breakdown always and for Correction whenever on-device
// isn't in play.
extension SettingsView {
    // On-device toggle, the shared remote Provider picker, and its key/search/temperature controls.
    @ViewBuilder
    var aiCorrectionSection: some View {
        Section {
            if AppleIntelligenceAvailability.isAvailable {
                Toggle("On-device Apple Intelligence", isOn: $appleIntelligenceEnabled)
            } else {
                LabeledContent("On-device Apple Intelligence", value: "Not available")
            }
            Picker("Provider", selection: $llmProviderRaw) {
                ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                    if isProviderSelectable(provider) {
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
            }
            // The key field for the selected provider only; edits write through to the Keychain.
            // A persistent leading label, not just the SecureField's own placeholder text — a
            // placeholder disappears the moment a key is typed in, leaving the row unlabeled.
            if selectedRemoteProvider == .openAI {
                HStack {
                    Text("OpenAI API Key")
                    Spacer()
                    SecureField("Required", text: $openAIKey)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: openAIKey) {
                            LLMSettings.setAPIKey(openAIKey, for: .openAI)
                            llmKeysRevision += 1
                        }
                }
            }
            if selectedRemoteProvider == .claude {
                HStack {
                    Text("Claude API Key")
                    Spacer()
                    SecureField("Required", text: $claudeKey)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: claudeKey) {
                            LLMSettings.setAPIKey(claudeKey, for: .claude)
                            llmKeysRevision += 1
                        }
                }
            }
            // Gated on the picker itself, not on whether Correction would currently route there —
            // Correction preferring on-device Apple Intelligence (the default whenever it's
            // available) would otherwise hide this permanently even with a remote provider
            // picked, since correctionRoutesToRemote would never be true. Breakdown always uses
            // the picked provider regardless of the on-device toggle, so the picker alone is the
            // right signal. Claude gets the server-side web_search tool; OpenAI swaps to its
            // search model. Costs more per call.
            if selectedRemoteProvider != .none {
                Toggle("Web Search", isOn: $useWebSearch)
            }
            // Temperature: same reasoning — gate on the picker, OpenAI only (Claude rejects the
            // parameter, on-device pins its own).
            if selectedRemoteProvider == .openAI,
               OpenAIRequestParameters.isReasoningModel(LLMSettings.openAIModel()) == false {
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
            Text("AI")
        }
    }

    // The picker's current value as a provider (Apple values from older builds read as none).
    private var selectedRemoteProvider: LLMProvider {
        let provider = LLMProvider(rawValue: llmProviderRaw) ?? .none
        return provider.isAppleIntelligence ? .none : provider
    }

    // Only remote providers are choices; Apple's variants are capabilities or unavailable.
    private func isProviderSelectable(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro:
            return false
        case .none, .openAI, .claude:
            return true
        }
    }
}
