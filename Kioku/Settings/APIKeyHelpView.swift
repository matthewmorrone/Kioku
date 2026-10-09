import SwiftUI

// The "Getting an API Key" help page, pushed from the AI section of Settings. Walks through
// creating an OpenAI key (and a Claude key in builds that offer Claude) and pasting it into Kioku.
// Sections: what the key is for, OpenAI steps, Claude steps (debug builds only), cost and privacy.
struct APIKeyHelpView: View {
    var body: some View {
        Form {
            Section {
                Text("Song breakdowns, AI corrections and meanings for words the dictionary doesn't have are sent to an AI service you choose. Kioku doesn't run its own server, so you bring your own key: requests go straight from this device to the service and are billed to your account there.")
            } header: {
                Text("What the Key Is For")
            }

            Section {
                HelpStepRow(number: 1, text: "Open platform.openai.com and sign in or create an account. This is separate from a ChatGPT subscription — ChatGPT Plus doesn't cover API use.")
                HelpStepRow(number: 2, text: "Under Settings → Billing, add a payment method and buy some credit. Keys work only while the account has credit.")
                HelpStepRow(number: 3, text: "Open API keys and tap Create new secret key. Give it a name such as \"Kioku\" and keep the default permissions.")
                HelpStepRow(number: 4, text: "Copy the key (it starts with sk-). OpenAI shows it only once; if you lose it, delete it and make a new one.")
                HelpStepRow(number: 5, text: "In Kioku, go to Settings → AI, set Provider to OpenAI and paste the key into OpenAI API Key.")
                Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                    Label("Open OpenAI API Keys", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("Doing this on a computer is easiest; you can AirDrop or paste the key over to your phone afterwards.")
            }

            if LLMSettings.isClaudeAvailable {
                Section {
                    HelpStepRow(number: 1, text: "Open platform.claude.com and sign in or create an account. A Claude.ai subscription doesn't cover API use.")
                    HelpStepRow(number: 2, text: "Under Settings → Billing, buy some credit.")
                    HelpStepRow(number: 3, text: "Go to Settings → API keys and tap Create key. Name it \"Kioku\".")
                    HelpStepRow(number: 4, text: "Copy the key (it starts with sk-ant-). It's shown only once.")
                    HelpStepRow(number: 5, text: "In Kioku, go to Settings → AI, set Provider to Claude and paste the key into Claude API Key.")
                    Link(destination: URL(string: "https://platform.claude.com/settings/keys")!) {
                        Label("Open Claude API Keys", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Claude is offered in development builds only.")
                }
            }

            Section {
                Text("Each request costs a fraction of a cent to a few cents, depending on how long the text is. Set a monthly spending limit on the service's billing page if you want a hard cap.")
                Text("Kioku keeps the key in this device's Keychain. It isn't part of Kioku's own backup files and is sent only to the service it belongs to.")
                Text("Only the text you ask about is sent — a note's lines for a breakdown or correction, or a word and the line it's in for a meaning.")
            } header: {
                Text("Cost and Privacy")
            } footer: {
                Text("To stop using AI features, set Provider to None. To revoke a key, delete it on the service's API keys page.")
            }
        }
        .navigationTitle("Getting an API Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}
