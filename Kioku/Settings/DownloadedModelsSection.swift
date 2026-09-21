import SwiftUI

// The four fixed-identity items DownloadedModelsStore manages (Whisper models are a
// variable-length list instead — see WhisperModelManager.downloadedModels).
private enum DownloadedModelKind: String, Identifiable, Equatable, CaseIterable {
    case qwenASR, qwenForcedAligner, htDemucs, vocalStems

    var id: String { rawValue }

    // Human-readable row label for each fixed-identity model.
    var displayName: String {
        switch self {
        case .qwenASR: return "Speech Recognition Model"
        case .qwenForcedAligner: return "Forced Aligner Model"
        case .htDemucs: return "Vocal Isolator Model"
        case .vocalStems: return "Cached Isolated Vocals"
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
        case .vocalStems: DownloadedModelsStore.deleteVocalStems()
        }
    }
}

// Settings → Downloaded and Caches sections. Downloaded lists the on-device speech models —
// "Clear Caches" never touches these, so this is the only place a user can reclaim the space:
// Qwen3-ASR, Qwen3-ForcedAligner, HTDemucs (all fixed-identity, one row each), plus any
// downloaded Whisper model (a variable-length list, previously only manageable
// from inside the Bulk Import flow). Hidden entirely when nothing is downloaded yet, mirroring
// Clear Caches disabling itself at 0 bytes.
struct DownloadedModelsSection: View {
    // Re-measures every row whenever the owner bumps this (e.g. after Clear Caches).
    var refreshToken: Int = 0
    // What Clear Caches would free (Library/Caches + tmp, measured by the owner), shown on the
    // button at the bottom of the Caches section; the rows above it sum to this figure.
    var cachesBytes: Int = 0
    var isClearingCaches: Bool = false
    var onClearCaches: () -> Void = {}
    // Called after any deletion here so the owner can re-measure its own storage readouts.
    var onStorageChanged: () -> Void = {}
    @State private var whisperModelManager = WhisperModelManager()
    @State private var qwenASRBytes: Int = 0
    @State private var qwenForcedAlignerBytes: Int = 0
    @State private var htDemucsBytes: Int = 0
    @State private var vocalStemsBytes: Int = 0
    @State private var cacheEntries: [DownloadedModelsStore.CacheEntry] = []
    @State private var cacheEntryPendingDeletion: DownloadedModelsStore.CacheEntry?
    @State private var modelPendingDeletion: DownloadedModelKind?
    @State private var isShowingDeleteDownloadedConfirmation = false
    @State private var whisperModelFilenamePendingDeletion: String?

    var body: some View {
        // Both sections are always mounted: the measuring `.task` below hangs off this Group, and a
        // conditionally absent view never runs its task — which left the list permanently empty
        // once every row started at zero.
        Group {
            Section {
                if qwenASRBytes > 0 || qwenForcedAlignerBytes > 0 || htDemucsBytes > 0
                    || whisperModelManager.downloadedModels.isEmpty == false {
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
                    Button(role: .destructive) {
                        isShowingDeleteDownloadedConfirmation = true
                    } label: {
                        Label("Delete Downloaded (\(formattedBytes(downloadedBytes)))", systemImage: "trash")
                    }
                } else {
                    Text("Empty").foregroundStyle(.secondary)
                }
            } header: {
                Text("Downloaded")
            }
            Section {
                // Rows are grouped by what they are, not where they live: the stems sit in
                // Application Support, but they are a cache and Clear Caches covers them.
                if vocalStemsBytes > 0 {
                    HStack {
                        Label(DownloadedModelKind.vocalStems.displayName, systemImage: "internaldrive")
                        Spacer()
                        Text(formattedBytes(vocalStemsBytes))
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            performVocalStemsDeletion()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                ForEach(cacheEntries) { entry in
                    HStack {
                        Label(entry.label, systemImage: "internaldrive")
                        Spacer()
                        Text(formattedBytes(entry.bytes))
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            cacheEntryPendingDeletion = entry
                            performCacheEntryDeletion()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                // Files below the listing cutoff, so the rows sum to the button exactly.
                let listed = vocalStemsBytes + cacheEntries.reduce(0) { $0 + $1.bytes }
                if cachesBytes > listed {
                    HStack {
                        Label("Other", systemImage: "doc")
                        Spacer()
                        Text(formattedBytes(cachesBytes - listed)).foregroundStyle(.secondary)
                    }
                }
                Button {
                    onClearCaches()
                } label: {
                    Label(cachesBytes > 0 ? "Clear Caches (\(formattedBytes(cachesBytes)))" : "Clear Caches",
                          systemImage: "trash")
                }
                .disabled(isClearingCaches || cachesBytes == 0)
            } header: {
                Text("Caches")
            }
        }
        .alert("Delete Everything Downloaded?", isPresented: $isShowingDeleteDownloadedConfirmation) {
            Button("Delete", role: .destructive) { performDeleteDownloaded() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(formattedBytes(downloadedBytes)). Models download again the next time they're needed.")
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
        .task(id: refreshToken) {
            whisperModelManager.refreshDownloadedModels()
            await refreshDownloadedModelBytes()
        }
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
                DownloadedModelsStore.htDemucsSizeBytes(),
                DownloadedModelsStore.vocalStemsSizeBytes(),
                DownloadedModelsStore.cacheEntries()
            )
        }.value
        qwenASRBytes = sizes.0
        qwenForcedAlignerBytes = sizes.1
        htDemucsBytes = sizes.2
        vocalStemsBytes = sizes.3
        cacheEntries = sizes.4
    }

    // Deletes the cache entry pending confirmation and re-measures, so the row disappears and the
    // Clear Caches readout shrinks to match.
    private func performCacheEntryDeletion() {
        guard let entry = cacheEntryPendingDeletion else { return }
        cacheEntryPendingDeletion = nil
        Task {
            await Task.detached(priority: .utility) { DownloadedModelsStore.delete(entry) }.value
            await refreshDownloadedModelBytes()
            onStorageChanged()
        }
    }

    // Deletes the cached isolated vocals straight away — cache rows take no confirmation — and
    // re-measures, so the row disappears and the Clear Caches readout shrinks to match.
    private func performVocalStemsDeletion() {
        Task {
            await Task.detached(priority: .utility) { DownloadedModelsStore.deleteVocalStems() }.value
            await refreshDownloadedModelBytes()
            onStorageChanged()
        }
    }

    // Deletes the fixed-identity model pending confirmation and re-measures its (now empty) size.
    private func performModelDeletion() {
        guard let kind = modelPendingDeletion else { return }
        modelPendingDeletion = nil
        Task {
            await Task.detached(priority: .utility) { kind.delete() }.value
            await refreshDownloadedModelBytes()
            onStorageChanged()
        }
    }

    // Sum of every row in the Downloaded section, for the Delete Downloaded button.
    private var downloadedBytes: Int {
        qwenASRBytes + qwenForcedAlignerBytes + htDemucsBytes
            + whisperModelManager.downloadedModels.reduce(0) { $0 + whisperModelManager.fileSizeBytes(filename: $1) }
    }

    // Deletes every model the Downloaded section lists, then re-measures.
    private func performDeleteDownloaded() {
        let whisperFiles = whisperModelManager.downloadedModels
        Task {
            await Task.detached(priority: .utility) { DownloadedModelKind.allCases.filter { $0 != .vocalStems }.forEach { $0.delete() } }.value
            for filename in whisperFiles { try? whisperModelManager.deleteModel(filename: filename) }
            await refreshDownloadedModelBytes()
            onStorageChanged()
        }
    }

    // Deletes the Whisper model pending confirmation — WhisperModelManager.deleteModel already
    // refreshes its own downloadedModels list, which this section observes.
    private func performWhisperModelDeletion() {
        guard let filename = whisperModelFilenamePendingDeletion else { return }
        whisperModelFilenamePendingDeletion = nil
        try? whisperModelManager.deleteModel(filename: filename)
        onStorageChanged()
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
