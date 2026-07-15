import SwiftUI

// The three fixed-identity speech models DownloadedModelsStore manages (Whisper models are a
// variable-length list instead — see WhisperModelManager.downloadedModels).
private enum DownloadedModelKind: String, Identifiable {
    case qwenASR, qwenForcedAligner, htDemucs

    var id: String { rawValue }

    // Human-readable row label for each fixed-identity model.
    var displayName: String {
        switch self {
        case .qwenASR: return "Speech Recognition Model"
        case .qwenForcedAligner: return "Forced Aligner Model"
        case .htDemucs: return "Vocal Isolator Model"
        }
    }

    // nonisolated: called from inside Task.detached (off the main actor) so deletion doesn't
    // block the Settings sheet — the project's default actor isolation is MainActor, so this
    // needs to opt out explicitly. Safe: it only calls DownloadedModelsStore's nonisolated
    // static funcs, plain FileManager I/O.
    nonisolated func delete() {
        switch self {
        case .qwenASR: DownloadedModelsStore.deleteQwenASR()
        case .qwenForcedAligner: DownloadedModelsStore.deleteQwenForcedAligner()
        case .htDemucs: DownloadedModelsStore.deleteHTDemucs()
        }
    }
}

// Settings → Downloaded Models section. Surfaces the on-device speech models that live outside
// Library/Caches (see DownloadedModelsStore's header) — "Clear Caches" never touches these, so
// this is the only place a user can reclaim the space: Qwen3-ASR, Qwen3-ForcedAligner, HTDemucs
// (all fixed-identity, one row each), plus any downloaded Whisper model (a variable-length list,
// previously only manageable from inside the Bulk Import flow). Hidden entirely when nothing is
// downloaded yet, mirroring Clear Caches disabling itself at 0 bytes.
struct DownloadedModelsSection: View {
    @State private var whisperModelManager = WhisperModelManager()
    @State private var qwenASRBytes: Int = 0
    @State private var qwenForcedAlignerBytes: Int = 0
    @State private var htDemucsBytes: Int = 0
    @State private var modelPendingDeletion: DownloadedModelKind?
    @State private var whisperModelFilenamePendingDeletion: String?

    var body: some View {
        Group {
            if qwenASRBytes > 0 || qwenForcedAlignerBytes > 0 || htDemucsBytes > 0
                || whisperModelManager.downloadedModels.isEmpty == false {
                Section {
                    if qwenASRBytes > 0 {
                        downloadedModelRow(kind: .qwenASR, bytes: qwenASRBytes)
                    }
                    if qwenForcedAlignerBytes > 0 {
                        downloadedModelRow(kind: .qwenForcedAligner, bytes: qwenForcedAlignerBytes)
                    }
                    if htDemucsBytes > 0 {
                        downloadedModelRow(kind: .htDemucs, bytes: htDemucsBytes)
                    }
                    ForEach(whisperModelManager.downloadedModels, id: \.self) { filename in
                        HStack {
                            Label("Whisper (\(filename))", systemImage: "waveform")
                            Spacer()
                            Text(formattedBytes(whisperModelManager.fileSizeBytes(filename: filename)))
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                whisperModelFilenamePendingDeletion = filename
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Downloaded Models")
                }
            }
        }
        .alert(
            "Delete \(modelPendingDeletion?.displayName ?? "Model")?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if $0 == false { modelPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { performModelDeletion() }
            Button("Cancel", role: .cancel) { modelPendingDeletion = nil }
        } message: {
            Text("This model will download again automatically the next time it's needed.")
        }
        .alert(
            "Delete Whisper Model?",
            isPresented: Binding(
                get: { whisperModelFilenamePendingDeletion != nil },
                set: { if $0 == false { whisperModelFilenamePendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { performWhisperModelDeletion() }
            Button("Cancel", role: .cancel) { whisperModelFilenamePendingDeletion = nil }
        } message: {
            Text("This model will download again automatically the next time it's needed.")
        }
        .task { await refreshDownloadedModelBytes() }
    }

    // One row for a fixed-identity model (Whisper's variable-length list is rendered inline in
    // `body` instead, since it has no DownloadedModelKind).
    @ViewBuilder
    private func downloadedModelRow(kind: DownloadedModelKind, bytes: Int) -> some View {
        HStack {
            Label(kind.displayName, systemImage: "waveform")
            Spacer()
            Text(formattedBytes(bytes))
                .foregroundStyle(.secondary)
        }
        .swipeActions {
            Button(role: .destructive) {
                modelPendingDeletion = kind
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // Scans the three fixed-identity model directories off the main thread — a deep model tree
    // (many safetensors shards) shouldn't stall the Settings sheet.
    private func refreshDownloadedModelBytes() async {
        let sizes = await Task.detached(priority: .utility) {
            (
                DownloadedModelsStore.qwenASRSizeBytes(),
                DownloadedModelsStore.qwenForcedAlignerSizeBytes(),
                DownloadedModelsStore.htDemucsSizeBytes()
            )
        }.value
        qwenASRBytes = sizes.0
        qwenForcedAlignerBytes = sizes.1
        htDemucsBytes = sizes.2
    }

    // Deletes the fixed-identity model pending confirmation and re-measures its (now empty) size.
    private func performModelDeletion() {
        guard let kind = modelPendingDeletion else { return }
        modelPendingDeletion = nil
        Task {
            await Task.detached(priority: .utility) { kind.delete() }.value
            await refreshDownloadedModelBytes()
        }
    }

    // Deletes the Whisper model pending confirmation — WhisperModelManager.deleteModel already
    // refreshes its own downloadedModels list, which this section observes.
    private func performWhisperModelDeletion() {
        guard let filename = whisperModelFilenamePendingDeletion else { return }
        whisperModelFilenamePendingDeletion = nil
        try? whisperModelManager.deleteModel(filename: filename)
    }

    // Renders a byte count as a human-readable string (e.g. "747 MB", "1.2 GB") — matches what
    // iPhone Storage shows so the in-app number reads the same as the system view. Duplicated
    // from SettingsView's private helper of the same name rather than shared, since it's five
    // lines and the two call sites are in different files.
    private func formattedBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
