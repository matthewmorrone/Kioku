import SwiftUI

// The AI section of Settings, extracted from SettingsView to keep the parent file under the
// project's 1000-line invariant. All @AppStorage / @State it uses live on SettingsView; this
// extension just shapes the UI. On-device Apple Intelligence is a capability the app uses on
// its own (correction, when present); the Provider picker is the remote model, used for
// breakdowns always and for correction when on-device isn't. The two status rows at the bottom
// state where each feature will actually run.
extension SettingsView {
    // On-device status and preference, remote provider and its key, per-provider options, and
    // the resolved route per feature.
    @ViewBuilder
    var aiCorrectionSection: some View {
        Section {
            LabeledContent("On-device Apple Intelligence",
                           value: AppleIntelligenceAvailability.isAvailable ? "Available" : "Not available")
            if AppleIntelligenceAvailability.isAvailable {
                Toggle("Prefer On-device for Correction", isOn: $preferOnDeviceCorrection)
            }
            Picker("Provider", selection: $llmProviderRaw) {
                ForEach(LLMProvider.allCases, id: \.rawValue) { provider in
                    if isProviderSelectable(provider) {
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }
            }
            // The key field for the selected provider only; edits write through to the Keychain.
            if selectedRemoteProvider == .openAI {
                SecureField("OpenAI API Key", text: $openAIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: openAIKey) {
                        LLMSettings.setAPIKey(openAIKey, for: .openAI)
                        llmKeysRevision += 1
                    }
            }
            if selectedRemoteProvider == .claude {
                SecureField("Claude API Key", text: $claudeKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: claudeKey) {
                        LLMSettings.setAPIKey(claudeKey, for: .claude)
                        llmKeysRevision += 1
                    }
            }
            // Web search: Claude gets the server-side web_search tool; OpenAI swaps to its search
            // model. Costs more per call. Temperature: OpenAI only (Claude rejects it, on-device
            // pins its own).
            if selectedRemoteProvider != .none {
                Toggle("Web Search", isOn: $useWebSearch)
            }
            if selectedRemoteProvider == .openAI {
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
            LabeledContent("Correction", value: correctionRoute)
            LabeledContent("Breakdown", value: breakdownRoute)
        } header: {
            Text("AI")
        }
    }

    // The picker's current value as a provider (Apple values from older builds read as none).
    private var selectedRemoteProvider: LLMProvider {
        let provider = LLMProvider(rawValue: llmProviderRaw) ?? .none
        return provider.isAppleIntelligence ? .none : provider
    }

    // Where a correction would run right now, or why it can't.
    private var correctionRoute: String {
        _ = llmKeysRevision
        let provider = LLMSettings.activeProvider()
        if provider == .none { return "Unavailable" }
        if provider.isAppleIntelligence { return provider.displayName }
        return LLMSettings.apiKey(for: provider) == nil ? "Needs API key" : provider.displayName
    }

    // Where a breakdown would run right now, or why it can't.
    private var breakdownRoute: String {
        _ = llmKeysRevision
        let provider = LLMSettings.breakdownProvider()
        if provider == .none { return "Needs a provider" }
        return LLMSettings.apiKey(for: provider) == nil ? "Needs API key" : provider.displayName
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
