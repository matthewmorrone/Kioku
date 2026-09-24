import SwiftUI

// The AI section of Settings, extracted from SettingsView to keep the parent file under the
// project's 1000-line invariant. All @AppStorage / @State it uses live on SettingsView; this
// extension just shapes the UI. The Provider picker is the remote model song breakdowns use
// (None / OpenAI, plus Claude in debug builds).
extension SettingsView {
    // The Provider picker and the selected provider's API key.
    @ViewBuilder
    var aiCorrectionSection: some View {
        Section {
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
        } header: {
            Text("AI")
        }
    }

    // The picker's current value as a provider (Apple values from older builds read as none).
    private var selectedRemoteProvider: LLMProvider {
        let provider = LLMProvider(rawValue: llmProviderRaw) ?? .none
        if provider.isAppleIntelligence { return .none }
        if provider == .claude, LLMSettings.isClaudeAvailable == false { return .none }
        return provider
    }

    // Only remote providers are choices; Apple's variants are capabilities or unavailable, and
    // Claude is offered in debug builds only (see LLMSettings.isClaudeAvailable).
    private func isProviderSelectable(_ provider: LLMProvider) -> Bool {
        switch provider {
        case .appleIntelligence, .appleIntelligenceCloud, .appleIntelligenceCloudPro:
            return false
        case .claude:
            return LLMSettings.isClaudeAvailable
        case .none, .openAI:
            return true
        }
    }
}
