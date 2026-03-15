import SwiftUI
import UniformTypeIdentifiers

// Sheet that lets the user pick an SRT subtitle file and an optional audio file to create
// a new note. Without audio the note is created from plain text; with audio it gains a
// play/pause bar in the reader that highlights the active cue during playback.
struct SubtitleImportSheet: View {
    // Called with the parsed cues and an optional audio URL when the user confirms import.
    var onImport: ([SubtitleCue], URL?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var subtitleURL: URL? = nil
    @State private var audioURL: URL? = nil
    @State private var isShowingSubtitlePicker = false
    @State private var isShowingAudioPicker = false
    @State private var subtitleError = ""
    @State private var audioError = ""
    @State private var parseError = ""

    var body: some View {
        NavigationStack {
            Form {
                // Subtitle file selector – required before import is allowed.
                Section {
                    Button {
                        isShowingSubtitlePicker = true
                    } label: {
                        HStack {
                            Label("Subtitle File", systemImage: "doc.text")
                            Spacer()
                            Text(subtitleURL?.lastPathComponent ?? "Choose…")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                    }
                } footer: {
                    if subtitleError.isEmpty == false {
                        Text(subtitleError).foregroundStyle(.red)
                    }
                    if parseError.isEmpty == false {
                        Text(parseError).foregroundStyle(.red)
                    }
                }

                // Audio file selector – optional; enables playback highlighting when provided.
                Section {
                    Button {
                        isShowingAudioPicker = true
                    } label: {
                        HStack {
                            Label("Audio File (optional)", systemImage: "waveform")
                            Spacer()
                            Text(audioURL?.lastPathComponent ?? "None")
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
                    if audioURL == nil {
                        Text("Without audio the note is created from the subtitle text only.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performImport()
                    }
                    .disabled(subtitleURL == nil)
                }
            }
            // Subtitle file picker – accepts .srt by extension and plain-text as a fallback.
            .fileImporter(
                isPresented: $isShowingSubtitlePicker,
                allowedContentTypes: subtitleContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    subtitleURL = urls.first
                    subtitleError = ""
                    parseError = ""
                case .failure(let error):
                    subtitleError = error.localizedDescription
                }
            }
            // Audio file picker – all audio types supported by AVAudioPlayer.
            .fileImporter(
                isPresented: $isShowingAudioPicker,
                allowedContentTypes: [.audio, .mp3],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    audioURL = urls.first
                    audioError = ""
                case .failure(let error):
                    audioError = error.localizedDescription
                }
            }
        }
    }

    // Reads and parses the chosen subtitle file then hands off to the caller.
    private func performImport() {
        guard let subtitleURL else { return }

        let didStartAccess = subtitleURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { subtitleURL.stopAccessingSecurityScopedResource() }
        }

        guard let rawContent = try? String(contentsOf: subtitleURL, encoding: .utf8)
                ?? String(contentsOf: subtitleURL, encoding: .isoLatin1) else {
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

    // Builds the allowed content types for the subtitle picker, preferring .srt when available.
    private var subtitleContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let srtType = UTType(filenameExtension: "srt") {
            types.insert(srtType, at: 0)
        }
        return types
    }
}
