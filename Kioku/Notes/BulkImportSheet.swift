import SwiftUI
import UniformTypeIdentifiers

// Renders the bulk-import sheet shown from NotesView. The screen has three vertically
// stacked sections: a file picker that accumulates txt/srt/audio URLs, a plan list that
// shows how the picker contents will become notes, and an optional Whisper model section
// shown only when at least one item needs transcription. Tapping Import runs the plan
// sequentially via BulkImportRunner; row status updates in place as items complete.
struct BulkImportSheet: View {
    @EnvironmentObject private var store: NotesStore
    @Environment(\.dismiss) private var dismiss

    @State private var pickedURLs: [URL] = []
    @State private var modelSource: WhisperModelSource?
    @State private var modelManager = WhisperModelManager()

    @State private var activePicker: BulkImportPickerTarget? = nil
    @State private var isPickerPresented = false
    @State private var isDownloadSheetPresented = false

    @State private var pickerError = ""
    @State private var modelError = ""

    // Transcription engine for this import. Backed by the same UserDefaults key the runner reads via
    // TranscriptionEngine.current, so picking here also sets the app-wide default.
    @AppStorage(TranscriptionEngine.storageKey) private var selectedEngineRaw: String = TranscriptionEngine.qwen3.rawValue
    private var selectedEngine: TranscriptionEngine { TranscriptionEngine(rawValue: selectedEngineRaw) ?? .qwen3 }

    // Isolate the vocal stem before transcribing — engine-independent. Default on (best for songs).
    @AppStorage(TranscriptionPreprocessing.isolateVocalsKey) private var isolateVocals = true

    @StateObject private var runner: BulkImportRunner

    // Captures the store at construction so the runner can mutate notes directly without
    // re-entering the environment chain from inside background-actor tasks.
    init(store: NotesStore) {
        _runner = StateObject(wrappedValue: BulkImportRunner(store: store))
    }

    // Computes the plan on the fly from the current picker state and store contents.
    // Done as a computed property rather than @State so adding/removing files immediately
    // updates the plan and the model-required indicator.
    //
    // The audio-basename map lets the planner match incoming files against notes whose titles
    // differ from the original audio filename (single-import flow titles notes by first cue line).
    private var plan: [BulkImportPlanItem] {
        var audioBaseNames: [UUID: String] = [:]
        for note in store.notes {
            guard let attachmentID = note.audioAttachmentID else { continue }
            guard let base = NotesAudioStore.shared.audioBaseName(for: attachmentID) else { continue }
            audioBaseNames[note.id] = base
        }
        return BulkImportPlanner.plan(
            urls: pickedURLs,
            existingNotes: store.notes,
            existingAudioBaseNamesByNoteID: audioBaseNames
        )
    }

    private var needsTranscription: Bool {
        plan.contains { BulkImportPlanner.requiresTranscription($0) }
    }

    private var canImport: Bool {
        guard runner.isRunning == false, runner.hasFinished == false else { return false }
        if plan.isEmpty { return false }
        // Only Whisper requires a downloaded model; Qwen3 / Apple Speech never block Import.
        if needsTranscription, modelSource == nil, selectedEngine == .whisper { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                pickerSection
                if plan.isEmpty == false {
                    planSection
                }
                if needsTranscription {
                    engineSection
                }
                // Whisper model picker only when transcription is needed AND Whisper is the selected
                // engine — Qwen3-ASR and Apple Speech transcribe without a downloaded model.
                if needsTranscription && selectedEngine == .whisper {
                    modelSection
                }
            }
            .navigationTitle("Bulk Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(runner.isRunning)
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmationButton
                }
            }
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: allowedContentTypesForActivePicker,
                allowsMultipleSelection: activePicker == .files
            ) { result in
                let target = activePicker
                activePicker = nil
                handlePickerResult(result, target: target)
            }
            .sheet(isPresented: $isDownloadSheetPresented) {
                WhisperDownloadSheet(manager: modelManager) { source in
                    modelSource = source
                    modelError = ""
                }
            }
        }
    }

    // Top section: lets the user pick more files and clear the current selection.
    // Picker errors render in the section footer so they appear inline with the trigger.
    @ViewBuilder
    private var pickerSection: some View {
        Section {
            Button {
                activePicker = .files
                isPickerPresented = true
            } label: {
                Label(pickedURLs.isEmpty ? "Choose Files…" : "Add More Files…", systemImage: "plus.rectangle.on.folder")
            }
            .disabled(runner.isRunning || runner.hasFinished)

            if pickedURLs.isEmpty == false, runner.hasFinished == false {
                Button("Clear Selection", role: .destructive) {
                    pickedURLs.removeAll()
                }
                .disabled(runner.isRunning)
            }
        } header: {
            Text("Files")
        } footer: {
            if pickerError.isEmpty == false {
                Text(pickerError).foregroundStyle(.red)
            } else {
                Text("Select .txt, .srt, .mp3 or .wav files. Files with the same name are paired into a single note.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Middle section: one row per plan item with action description and status indicator.
    @ViewBuilder
    private var planSection: some View {
        Section {
            ForEach(plan) { item in
                planRow(for: item)
            }
        } header: {
            Text("Plan (\(plan.count))")
        }
    }

    // Bottom section: Whisper model selection. Shown only when at least one plan item
    // Transcription engine picker (shown whenever an item needs transcription). Writes the app-wide
    // engine setting, so Apple Speech / Qwen3 / Whisper can be chosen right here in the import.
    @ViewBuilder
    private var engineSection: some View {
        Section {
            Picker("Engine", selection: $selectedEngineRaw) {
                ForEach(TranscriptionEngine.allCases, id: \.rawValue) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .disabled(runner.isRunning)
            Toggle("Isolate vocals first", isOn: $isolateVocals)
                .disabled(runner.isRunning)
        } header: {
            Text("Transcription Engine")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                switch selectedEngine {
                case .qwen3:       Text("On-device Qwen3-ASR. No download.")
                case .appleSpeech: Text("Apple's system recognizer — lowest memory. No download.")
                case .whisper:     Text("On-device Whisper — needs the model selected below.")
                }
                Text(isolateVocals
                     ? "Separates vocals from the backing track first — best for songs (heavier; cached)."
                     : "Transcribes the raw mix — right for plain speech and lowest memory.")
            }
        }
    }

    // needs transcription. Mirrors SubtitleImportSheet so the picker UX is consistent.
    @ViewBuilder
    private var modelSection: some View {
        Section {
            Button {
                isDownloadSheetPresented = true
            } label: {
                HStack {
                    Label("Download Model…", systemImage: "arrow.down.circle")
                    Spacer()
                    if case .downloaded(let name) = modelSource {
                        Text(name).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }
            .disabled(runner.isRunning)

            Button {
                activePicker = .model
                isPickerPresented = true
            } label: {
                HStack {
                    Label("Choose File…", systemImage: "doc")
                    Spacer()
                    if case .userFile(let url) = modelSource {
                        Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .foregroundStyle(.primary)
            }
            .disabled(runner.isRunning)
        } header: {
            Text("Whisper Model")
        } footer: {
            if modelError.isEmpty == false {
                Text(modelError).foregroundStyle(.red)
            } else {
                Text("Required for items with audio but no text or subtitle.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Renders one plan-item row including the action description and live status.
    @ViewBuilder
    private func planRow(for item: BulkImportPlanItem) -> some View {
        let progress = runner.progressByItem[item.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                fileTypeChips(for: item)
                Text(item.baseName.isEmpty ? "Untitled" : item.baseName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusIndicator(for: progress)
            }

            Text(BulkImportPlanner.actionDescription(item))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if case .running = progress?.status, BulkImportPlanner.requiresTranscription(item) {
                // Stage + percentage above the bar (e.g. "Isolating vocals…   42%"), matching the
                // alignment progress UI, so the user always sees what's happening and how far along.
                let label = progress?.statusLabel ?? ""
                let pct = Int(((progress?.transcriptionProgress ?? 0) * 100).rounded())
                HStack(spacing: 6) {
                    Text(label.isEmpty ? "Transcribing…" : label)
                    Spacer(minLength: 4)
                    Text("\(pct)%").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ProgressView(value: progress?.transcriptionProgress ?? 0)
            }

            if case .failed(let message) = progress?.status {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if runner.isRunning == false, runner.hasFinished == false {
                Button(role: .destructive) {
                    removePlanItem(item)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    // Compact icons for each file kind included in an item so users can see at a glance
    // which inputs make up the row.
    @ViewBuilder
    private func fileTypeChips(for item: BulkImportPlanItem) -> some View {
        HStack(spacing: 4) {
            if item.textURL != nil {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
            if item.subtitleURL != nil {
                Image(systemName: "captions.bubble").foregroundStyle(.secondary)
            }
            if item.audioURL != nil {
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    // Renders a per-row status badge: queued (clock), running (spinner), done (check),
    // failed (warning). Nil progress maps to queued so newly-added items display correctly.
    @ViewBuilder
    private func statusIndicator(for progress: BulkImportItemProgress?) -> some View {
        switch progress?.status ?? .queued {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    // Builds the confirmation-action button. Switches between Import, an in-flight
    // spinner, and Done so the user knows when the run has completed.
    @ViewBuilder
    private var confirmationButton: some View {
        if runner.hasFinished {
            Button("Done") { dismiss() }
        } else if runner.isRunning {
            ProgressView()
        } else {
            Button("Import") {
                Task { await startImport() }
            }
            .disabled(canImport == false)
        }
    }

    // Launches the runner with the current plan and resolved model URL.
    private func startImport() async {
        let snapshot = plan
        let modelURL = modelSource.flatMap { modelManager.resolvedURL(for: $0) }
        await runner.run(plan: snapshot, whisperModelURL: modelURL)
    }

    // Dispatches a picker result to either the files or model slot based on the active target.
    // Dedupes selected files by standardized path so repeat selections do not produce duplicate rows.
    private func handlePickerResult(_ result: Result<[URL], Error>, target: BulkImportPickerTarget?) {
        switch result {
        case .success(let urls):
            switch target {
            case .files:
                var seen = Set(pickedURLs.map { $0.standardizedFileURL.path })
                for url in urls {
                    let key = url.standardizedFileURL.path
                    if seen.insert(key).inserted {
                        pickedURLs.append(url)
                    }
                }
                pickerError = ""
            case .model:
                guard let url = urls.first else { return }
                modelSource = .userFile(url)
                modelError = ""
            case nil:
                break
            }
        case .failure(let error):
            switch target {
            case .files: pickerError = error.localizedDescription
            case .model: modelError = error.localizedDescription
            case nil: break
            }
        }
    }

    // Removes every URL that contributed to one plan item so the row disappears from the list.
    private func removePlanItem(_ item: BulkImportPlanItem) {
        let urlsToRemove = [item.textURL, item.subtitleURL, item.audioURL].compactMap { $0 }
        let pathsToRemove = Set(urlsToRemove.map { $0.standardizedFileURL.path })
        pickedURLs.removeAll { pathsToRemove.contains($0.standardizedFileURL.path) }
    }

    // Resolves the allowed content types for the currently pending picker request so the
    // single .fileImporter modifier can serve both the bulk-files picker and the model picker.
    private var allowedContentTypesForActivePicker: [UTType] {
        switch activePicker {
        case .files:
            // NOTE: don't add `.text` here — it's the parent UTI of `public.text`, which
            // also covers `.json`, `.html`, `.swift`, etc. Users importing alongside the
            // `.json` artifacts produced by the alignment service would see them appear in
            // the picker (then get silently dropped by BulkImportPlanner because the
            // extension isn't in any of its lists). `.plainText` is the txt-specific UTI.
            var types: [UTType] = [.plainText, .audio, .mp3, .mpeg4Audio]
            if let srt = UTType(filenameExtension: "srt") {
                types.append(srt)
            }
            if let wav = UTType(filenameExtension: "wav") {
                types.append(wav)
            }
            if let textGridLower = UTType(filenameExtension: "textgrid") {
                types.append(textGridLower)
            }
            if let textGridMixed = UTType(filenameExtension: "TextGrid") {
                types.append(textGridMixed)
            }
            return types
        case .model:
            var types: [UTType] = [.data]
            if let bin = UTType(filenameExtension: "bin") {
                types.insert(bin, at: 0)
            }
            return types
        case nil:
            return [.item]
        }
    }
}

// Identifies which picker is currently active in BulkImportSheet so a single .fileImporter
// modifier can dispatch the result to the correct slot.
enum BulkImportPickerTarget {
    case files
    case model
}
