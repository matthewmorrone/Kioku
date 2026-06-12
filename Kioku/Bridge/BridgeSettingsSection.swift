import SwiftUI

// Settings → MCP Bridge section. Toggles the local-network listener, surfaces
// the bearer token and LAN address so the user can paste them into the Pi's
// MCP server config, and shows the current run state for trouble-shooting.
//
// Layout sections:
//   1. Toggle row + run-state summary
//   2. Connection details (host, port, token) revealed only when on
//   3. Maintenance row (regenerate token, copy URL)
struct BridgeSettingsSection: View {
    // The bridge server is constructed by the parent so its lifetime matches
    // the SettingsView's surrounding scope.
    @ObservedObject var bridgeServer: KiokuBridgeServer

    @AppStorage(BridgeSettings.enabledKey) private var enabled: Bool = false
    @AppStorage(BridgeSettings.portKey) private var port: Int = BridgeSettings.defaultPort
    // The token authenticates LAN clients, so it lives in the Keychain; this is the
    // display copy. Only this view mutates the token, so @State stays in sync.
    @State private var token: String = ""

    @State private var lanAddresses: [String] = []
    @State private var revealToken: Bool = false

    var body: some View {
        Section {
            Toggle("MCP Bridge", isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    handleToggle(newValue: newValue)
                }

            statusRow

            if enabled {
                connectionRows
                maintenanceRows
            }
        } header: {
            Text("MCP Bridge")
        } footer: {
            Text("Hosts a local-network HTTP endpoint that lets a Claude MCP server (e.g. running on a Raspberry Pi) read and edit your notes, segmentation, and furigana while Kioku is open.")
        }
        .onAppear {
            refreshLANAddresses()
            // Provision a token on first reveal so the field never appears blank.
            token = BridgeSettings.currentOrProvisionedToken()
            // Reflect on-disk enabled state into the live server when the screen first appears.
            if enabled, case .stopped = bridgeServer.state {
                bridgeServer.start()
            }
        }
    }

    // Single-line summary that explains the listener's current state in plain words.
    private var statusRow: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text(statusDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // Host, port, and token fields shown only when the bridge is enabled.
    @ViewBuilder
    private var connectionRows: some View {
        if let primary = lanAddresses.first {
            LabeledContent("Host", value: primary)
        } else {
            LabeledContent("Host", value: "no LAN interface")
        }

        Stepper(value: $port, in: BridgeSettings.minPort...BridgeSettings.maxPort) {
            LabeledContent("Port", value: "\(port)")
        }
        .onChange(of: port) { _, _ in
            // Restart the listener so the new port takes effect immediately.
            if enabled {
                bridgeServer.stop()
                bridgeServer.start()
            }
        }

        HStack {
            Text("Token")
            Spacer()
            if revealToken {
                Text(token)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(repeating: "•", count: min(token.count, 12)))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button(revealToken ? "Hide" : "Show") {
                revealToken.toggle()
            }
            .font(.footnote)
            .buttonStyle(.borderless)
        }

        if lanAddresses.count > 1 {
            DisclosureGroup("Other addresses") {
                ForEach(lanAddresses.dropFirst(), id: \.self) { address in
                    Text(address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // Buttons to regenerate the token and copy a ready-to-paste connection URL.
    private var maintenanceRows: some View {
        Group {
            Button {
                copyConnectionDetails()
            } label: {
                Label("Copy Connection Info", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                regenerateToken()
            } label: {
                Label("Regenerate Token", systemImage: "arrow.clockwise")
            }
        }
    }

    // Drives the listener on/off in response to the toggle.
    private func handleToggle(newValue: Bool) {
        if newValue {
            token = BridgeSettings.currentOrProvisionedToken()
            refreshLANAddresses()
            bridgeServer.start()
        } else {
            bridgeServer.stop()
        }
    }

    // Refreshes the cached interface list so the displayed LAN IP stays accurate
    // when the user joins a different Wi-Fi network mid-session.
    private func refreshLANAddresses() {
        lanAddresses = BridgeAddressFinder.currentLANAddresses()
    }

    // Invalidates the current token, generating a fresh one. The Pi-side env
    // file must be updated to match before the next request will be accepted.
    private func regenerateToken() {
        token = BridgeSettings.regenerateToken()
        if enabled {
            bridgeServer.stop()
            bridgeServer.start()
        }
    }

    // Drops a one-line summary onto the clipboard so the user doesn't have to
    // transcribe the LAN IP, port, and token across devices.
    private func copyConnectionDetails() {
        let host = lanAddresses.first ?? "<host>"
        let info = """
        KIOKU_BRIDGE_URL=http://\(host):\(port)
        KIOKU_BRIDGE_TOKEN=\(token)
        """
        UIPasteboard.general.string = info
    }

    // Small derived helpers that map run state to UI affordances.
    private var statusIcon: String {
        switch bridgeServer.state {
        case .stopped: return "circle"
        case .starting: return "circle.dotted"
        case .running: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch bridgeServer.state {
        case .stopped: return .secondary
        case .starting: return .secondary
        case .running: return .green
        case .failed: return .red
        }
    }

    private var statusDescription: String {
        switch bridgeServer.state {
        case .stopped:
            return enabled ? "Listener stopped." : "Listener off."
        case .starting:
            return "Starting listener…"
        case .running(let port):
            return "Listening on port \(port)."
        case .failed(let message):
            return "Failed: \(message)"
        }
    }
}
