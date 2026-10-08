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
            // Label, ⓘ and picker laid out by hand: inside a menu picker's own label the ⓘ would
            // open the menu instead of its popover.
            HStack {
                Text("Provider")
                InfoButton(text: "The AI service Kioku sends these requests to. With None, song breakdowns and AI corrections are off. OpenAI needs your own API key from platform.openai.com: requests are billed to that account, and the key stays on this device in the Keychain.")
                Spacer()
                Picker("Provider", selection: $llmProviderRaw) {
                    ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                        if isProviderSelectable(provider) {
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                }
                .labelsHidden()
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
        } footer: {
            Text("Used for song breakdowns, AI corrections to a note's word splits and readings, and meanings for words the dictionary doesn't have.")
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
