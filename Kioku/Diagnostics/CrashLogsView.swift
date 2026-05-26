import SwiftUI
import UIKit

// Settings → Diagnostics → "Crash Logs". Lists every JSON record CrashLogger persisted,
// shows the contents inline, and offers share + delete-all so the user can ship a crash
// off the device via Files or Mail without needing Xcode / sysdiagnose.
struct CrashLogsView: View {
    @State private var files: [URL] = []
    @State private var selectedFile: URL?

    var body: some View {
        List {
            if files.isEmpty {
                Section {
                    Text("No crashes captured.")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Stored in the app sandbox at Documents/crashes/. CrashLogger captures uncaught exceptions, POSIX signals, and MetricKit post-mortem payloads (including OOM kills).")
                        .font(.footnote)
                }
            } else {
                Section {
                    ForEach(files, id: \.self) { file in
                        Button {
                            selectedFile = file
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.lastPathComponent).font(.callout)
                                if let size = fileSize(file) {
                                    Text(size).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(files.count) record\(files.count == 1 ? "" : "s")")
                }

                Section {
                    Button("Clear All", role: .destructive) {
                        CrashLogger.shared.clearCrashFiles()
                        refresh()
                    }
                }
            }
        }
        .navigationTitle("Crash Logs")
        .onAppear { refresh() }
        .sheet(item: Binding(
            get: { selectedFile.map(CrashFileWrapper.init) },
            set: { selectedFile = $0?.url }
        )) { wrapper in
            CrashFileDetailView(file: wrapper.url)
        }
    }

    // Reloads the file list from disk. Cheap; just a directory enumerate.
    private func refresh() {
        files = CrashLogger.shared.listCrashFiles()
    }

    // Returns a human-readable file size for the row subtitle.
    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// Sheet wrapper because URL isn't Identifiable on its own.
private struct CrashFileWrapper: Identifiable {
    let url: URL
    var id: URL { url }
}

// Renders one crash record's JSON inside a scrollable text view + share button so the
// user can AirDrop / mail / save the file off the device.
private struct CrashFileDetailView: View {
    let file: URL
    @Environment(\.dismiss) private var dismiss

    private var contents: String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? "(unreadable)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(contents)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(file.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: file)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
