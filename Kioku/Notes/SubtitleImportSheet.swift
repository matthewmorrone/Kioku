import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import SwiftWhisper

// Sheet for importing audio and/or subtitle files to create a new note.
// When audio is provided without a subtitle, Whisper transcription generates timing cues on-device.
struct SubtitleImportSheet: View {
    // Called with parsed or transcribed cues and an optional audio URL when the user confirms.
    var onImport: ([SubtitleCue], URL?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var audioURL: URL? = nil
    @State private var subtitleURL: URL? = nil
    @State private var modelSource: WhisperModelSource? = nil

    @State private var activePicker: ImportPickerTarget? = nil
    @State private var isPickerPresented = false
    @State private var isDownloadSheetPresented = false

    @State private var audioError = ""
    @State private var subtitleError = ""
    @State private var parseError = ""
    @State private var modelError = ""
    @State private var transcriptionError = ""

    @State private var isTranscribing = false
    @State private var transcriptionProgress: Double = 0
    @State private var liveSegments: [String] = []
    @State private var modelManager = WhisperModelManager()

    // True when audio is present but no subtitle is selected — triggers the Whisper transcription path.
    private var needsTranscription: Bool {
        audioURL != nil && subtitleURL == nil
    }

    private var canImport: Bool {
        guard isTranscribing == false else { return false }
        if needsTranscription { return audioURL != nil && modelSource != nil }
        return audioURL != nil || subtitleURL != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // Audio file — primary input; enables playback and transcription when no subtitle is given.
                Section {
                    Button {
                        activePicker = .audio
                        isPickerPresented = true
                    } label: {
                        HStack {
                            Label("Audio File", systemImage: "waveform")
                            Spacer()
                            Text(audioURL?.lastPathComponent ?? "Choose…")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                    }

                    if audioURL != nil {
                        Button("Remove Audio", role: .destructive) {
                            audioURL = nil
                        }
                    }
                } footer: {
                    if audioError.isEmpty == false {
                        Text(audioError).foregroundStyle(.red)
                    }
                }

                // Subtitle file — optional. When omitted with audio present, Whisper generates cues.
                Section {
                    Button {
                        activePicker = .subtitle
                        isPickerPresented = true
                    } label: {
                        HStack {
                            Label("Subtitle File", systemImage: "doc.text")
                            Spacer()
                            Text(subtitleURL?.lastPathComponent ?? "None")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                    }

                    if subtitleURL != nil {
                        Button("Remove Subtitle", role: .destructive) {
                            subtitleURL = nil
                            parseError = ""
                        }
                    }
                } footer: {
                    if subtitleError.isEmpty == false {
                        Text(subtitleError).foregroundStyle(.red)
                    }
                    if parseError.isEmpty == false {
                        Text(parseError).foregroundStyle(.red)
                    }
                    if needsTranscription {
                        Text("No subtitle — audio will be transcribed using Whisper.")
                            .foregroundStyle(.secondary)
                    }
                }

                // Whisper model selection — only shown when transcription is required.
                // Offers downloaded models, internet download, or a file picker.
                if needsTranscription {
                    Section {
                        // Download a model.
                        Button {
                            isDownloadSheetPresented = true
                        } label: {
                            HStack {
                                Label("Download Model…", systemImage: "arrow.down.circle")
                                Spacer()
                                if case .downloaded(let name) = modelSource {
                                    Text(name)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(.primary)
                        }

                        // Choose a local .bin file via the file picker.
                        Button {
                            activePicker = .model
                            isPickerPresented = true
                        } label: {
                            HStack {
                                Label("Choose File…", systemImage: "doc")
                                Spacer()
                                if case .userFile(let url) = modelSource {
                                    Text(url.lastPathComponent)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    } header: {
                        Text("Whisper Model")
                    } footer: {
                        if modelError.isEmpty == false {
                            Text(modelError).foregroundStyle(.red)
                        } else {
                            Text("Download a model for transcription, or choose a local file.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Live transcription feed — shows segments as Whisper emits them.
                if isTranscribing || liveSegments.isEmpty == false {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                if isTranscribing { ProgressView() }
                                Text(isTranscribing ? "Transcribing…" : "Done")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }

                            ScrollViewReader { proxy in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(liveSegments.enumerated()), id: \.offset) { _, text in
                                            Text(text)
                                                .font(.body)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        // Invisible anchor for auto-scroll.
                                        Color.clear.frame(height: 1).id("bottom")
                                    }
                                    .padding(.vertical, 4)
                                }
                                .frame(maxHeight: 200)
                                .onChange(of: liveSegments.count) {
                                    withAnimation { proxy.scrollTo("bottom") }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if transcriptionError.isEmpty == false {
                    Section {
                        Text(transcriptionError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isTranscribing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performImport()
                    }
                    .disabled(canImport == false)
                }
            }
            .fileImporter(
                isPresented: $isPickerPresented,
                allowedContentTypes: allowedContentTypesForActivePicker,
                allowsMultipleSelection: false
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

    // Routes import to the transcription or direct-parse path depending on available files.
    private func performImport() {
        if needsTranscription {
            Task { await transcribeAndImport() }
        } else {
            importWithSubtitle()
        }
    }

    // Reads and parses the chosen subtitle file, then hands off to the caller.
    private func importWithSubtitle() {
        guard let subtitleURL else { return }

        let didStartAccess = subtitleURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { subtitleURL.stopAccessingSecurityScopedResource() }
        }

        guard let rawContent = (try? String(contentsOf: subtitleURL, encoding: .utf8))
                ?? (try? String(contentsOf: subtitleURL, encoding: .isoLatin1)) else {
            parseError = "Could not read the subtitle file."
            return
        }

        let cues = SubtitleParser.parse(rawContent)
        guard cues.isEmpty == false else {
            parseError = "No subtitle cues were found in the selected file."
            return
        }

        onImport(cues, audioURL)
        dismiss()
    }

    // Converts the audio file to 16 kHz mono PCM, runs Whisper inference, then hands cues to the caller.
    private func transcribeAndImport() async {
        guard let audioURL else { return }
        guard let source = modelSource, let modelURL = modelManager.resolvedURL(for: source) else {
            transcriptionError = "Select a Whisper model before importing."
            return
        }

        isTranscribing = true
        transcriptionProgress = 0
        liveSegments = []
        transcriptionError = ""
        defer { isTranscribing = false }

        let didStartAudio = audioURL.startAccessingSecurityScopedResource()
        // Only user-picked files need security-scoped access; harmless to call on app-support URLs.
        let didStartModel = modelURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAudio { audioURL.stopAccessingSecurityScopedResource() }
            if didStartModel { modelURL.stopAccessingSecurityScopedResource() }
        }

        print("[Whisper] loading model from \(modelURL.path)")
        do {
            let audioFrames = try await convertAudioTo16kHzMono(url: audioURL)
            print("[Whisper] audio converted: \(audioFrames.count) frames at 16 kHz")

            let params = WhisperParams.default
            params.language = .japanese
            print("[Whisper] starting transcription (language: ja)")

            let whisper = Whisper(fromFileURL: modelURL, withParams: params)
            let delegate = WhisperTranscriptionDelegate()
            delegate.onProgress = { progress in
                Task { @MainActor in self.transcriptionProgress = progress }
            }
            delegate.onNewSegments = { segments in
                let texts = segments
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                Task { @MainActor in self.liveSegments.append(contentsOf: texts) }
            }
            whisper.delegate = delegate

            let segments = try await whisper.transcribe(audioFrames: audioFrames)

            var cues: [SubtitleCue] = []
            for (i, segment) in segments.enumerated() {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.isEmpty == false else { continue }
                cues.append(SubtitleCue(index: i + 1, startMs: segment.startTime, endMs: segment.endTime, text: text))
            }

            guard cues.isEmpty == false else {
                await MainActor.run {
                    transcriptionError = "Whisper returned no segments — the audio may be silent or the model incompatible."
                }
                return
            }

            await MainActor.run {
                onImport(cues, audioURL)
                dismiss()
            }
        } catch {
            await MainActor.run {
                transcriptionError = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }

    // Reads audio from the given URL and resamples it to 16 kHz mono Float32 using AVAssetReader.
    // Whisper requires exactly this format; AVAssetReader handles arbitrary source formats natively.
    private func convertAudioTo16kHzMono(url: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else {
                throw SubtitleImportError.noAudioTrack
            }

            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]

            let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            trackOutput.alwaysCopiesSampleData = false
            reader.add(trackOutput)

            guard reader.startReading() else {
                throw reader.error ?? SubtitleImportError.audioReadFailed
            }

            var samples: [Float] = []
            while reader.status == .reading {
                guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var rawBytes = [UInt8](repeating: 0, count: length)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &rawBytes)
                rawBytes.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    let floatPtr = base.assumingMemoryBound(to: Float.self)
                    samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: length / MemoryLayout<Float>.size))
                }
            }

            if reader.status == .failed, let error = reader.error {
                throw error
            }

            return samples
        }.value
    }

    // Dispatches a picker result to the correct URL slot and clears stale errors.
    private func handlePickerResult(_ result: Result<[URL], Error>, target: ImportPickerTarget?) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch target {
            case .audio:
                audioURL = url
                audioError = ""
            case .subtitle:
                subtitleURL = url
                subtitleError = ""
                parseError = ""
            case .model:
                modelSource = .userFile(url)
                modelError = ""
            case nil:
                break
            }
        case .failure(let error):
            switch target {
            case .audio: audioError = error.localizedDescription
            case .subtitle: subtitleError = error.localizedDescription
            case .model: modelError = error.localizedDescription
            case nil: break
            }
        }
    }

    // Returns allowed content types for the currently pending picker request.
    private var allowedContentTypesForActivePicker: [UTType] {
        switch activePicker {
        case .audio:
            return [.audio, .mpeg4Audio, .mp3]
        case .subtitle:
            var types: [UTType] = [.plainText, .text]
            if let srtType = UTType(filenameExtension: "srt") {
                types.insert(srtType, at: 0)
            }
            return types
        case .model:
            // .bin is not a standard UTType; .data covers arbitrary binary files.
            var types: [UTType] = [.data]
            if let binType = UTType(filenameExtension: "bin") {
                types.insert(binType, at: 0)
            }
            return types
        case nil:
            return [.item]
        }
    }

}

// Identifies which file picker is currently active in SubtitleImportSheet.
enum ImportPickerTarget {
    case audio
    case subtitle
    case model
}

// Errors produced during audio reading and PCM format conversion.
private enum SubtitleImportError: LocalizedError {
    case noAudioTrack
    case audioReadFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "The selected file contains no audio track."
        case .audioReadFailed: return "Could not read audio data from the selected file."
        }
    }
}
