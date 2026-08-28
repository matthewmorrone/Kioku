import SwiftUI
import UIKit

// Renders Settings → Debug Logs: a per-LogFeature on/off toggle list plus actions on the shared
// on-disk log mirror (AppLogFileSink). Layout: one row per LogFeature with its detail text as a
// caption, and (DEBUG builds only, since the file sink only exists there) a section showing the
// mirror's current size with copy-path and clear actions.
struct LogSettingsView: View {
    // One stored toggle per feature, seeded from LogFeatureSettings so the list reflects
    // whatever was persisted (or the all-enabled default) the moment the view appears.
    @State private var enabledByFeature: [LogFeature: Bool] = Dictionary(
        uniqueKeysWithValues: LogFeature.allCases.map { ($0, LogFeatureSettings.isEnabled($0)) }
    )
    #if DEBUG
    @State private var fileSizeBytes: Int = AppLogFileSink.currentSizeBytes()
    #endif

    var body: some View {
        Form {
            Section {
                ForEach(LogFeature.allCases) { feature in
                    Toggle(isOn: binding(for: feature)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.displayName)
                            Text(feature.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Features")
            }

            #if DEBUG
            Section {
                Text("\(fileSizeBytes) bytes")
                    .foregroundStyle(.secondary)
                Button("Copy Log File Path") {
                    UIPasteboard.general.string = AppLogFileSink.fileURL.path
                }
                Button("Clear Log File", role: .destructive) {
                    AppLogFileSink.clear()
                    fileSizeBytes = AppLogFileSink.currentSizeBytes()
                }
            } header: {
                Text("On-Disk Mirror")
            }
            #endif
        }
    }

    // Bridges one feature's local @State toggle to LogFeatureSettings' UserDefaults-backed
    // storage, so flipping a row both updates the visible switch and persists immediately.
    private func binding(for feature: LogFeature) -> Binding<Bool> {
        Binding(
            get: { enabledByFeature[feature] ?? true },
            set: { newValue in
                enabledByFeature[feature] = newValue
                LogFeatureSettings.setEnabled(feature, newValue)
            }
        )
    }
}
