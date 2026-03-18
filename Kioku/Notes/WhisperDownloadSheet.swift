import SwiftUI

// Sheet presenting downloadable Whisper models with per-row progress and error state.
// Rendered inside the model selection section of SubtitleImportSheet.
struct WhisperDownloadSheet: View {
    @Bindable var manager: WhisperModelManager

    // Called when the user selects an already-downloaded model to use immediately.
    var onSelect: (WhisperModelSource) -> Void

    @Environment(\.dismiss) private var dismiss

    // Tracks active download Tasks so they can be cancelled.
    @State private var downloadTasks: [String: Task<Void, Never>] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section("Available Models") {
                    ForEach(WhisperDownloadableModel.all) { model in
                        modelRow(for: model)
                    }
                }

                if manager.downloadedModels.isEmpty == false {
                    Section("Downloaded — tap to use") {
                        ForEach(manager.downloadedModels, id: \.self) { filename in
                            downloadedRow(filename: filename)
                        }
                    }
                }
            }
            .navigationTitle("Whisper Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // Row for a model that can be downloaded; shows progress or a download button.
    // If the model is bundled in the app, it counts as already available without downloading.
    @ViewBuilder
    private func modelRow(for model: WhisperDownloadableModel) -> some View {
        let filename = model.filename
        let isBundled = filename == "ggml-tiny.bin" && manager.hasBundledTiny
        let isDownloaded = manager.downloadedModels.contains(filename) || isBundled
        let progress = manager.downloadProgress[filename]
        let errorMessage = manager.downloadErrors[filename]

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    if isBundled && !manager.downloadedModels.contains(filename) {
                        Text("Built-in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("~\(model.sizeMB) MB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isDownloaded {
                    Button {
                        onSelect(isBundled && !manager.downloadedModels.contains(filename) ? .bundled : .downloaded(filename))
                        dismiss()
                    } label: {
                        Label("Use", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                } else if let progress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 80)
                        Button {
                            downloadTasks[filename]?.cancel()
                            downloadTasks.removeValue(forKey: filename)
                            manager.cancelDownload(filename: filename)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button {
                        let task = Task { await manager.download(model) }
                        downloadTasks[filename] = task
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    // Row for an already-downloaded model, with a tap-to-use action and swipe-to-delete.
    @ViewBuilder
    private func downloadedRow(filename: String) -> some View {
        Button {
            onSelect(.downloaded(filename))
            dismiss()
        } label: {
            HStack {
                Text(filename)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                try? manager.deleteModel(filename: filename)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
