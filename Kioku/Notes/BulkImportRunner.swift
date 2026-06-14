import Foundation
import AVFoundation
import Combine
import SwiftWhisper

// Executes a BulkImportPlan sequentially: parses txt/srt files, copies audio attachments,
// and runs Whisper transcription in the background for audio-only items. Items run one at
// a time so a single Whisper model is not loaded concurrently and so per-item progress is
// easy to surface in the sheet UI.
@MainActor
final class BulkImportRunner: ObservableObject {
    // Per-item progress keyed by plan item id. Drives the sheet's progress rows.
    @Published private(set) var progressByItem: [String: BulkImportItemProgress] = [:]
    // True while `run(plan:whisperModelURL:)` is iterating items.
    @Published private(set) var isRunning = false
    // True after a run completes (success or failure). Used by the sheet to swap Import → Done.
    @Published private(set) var hasFinished = false

    private let store: NotesStore

    // Stores a reference to the notes store so the runner can insert and update notes
    // without coupling the sheet UI to underlying persistence details.
    init(store: NotesStore) {
        self.store = store
    }

    // Walks the supplied plan in order, recording per-item status as each item processes.
    // Errors are captured into the item's status and do not abort subsequent items.
    func run(plan: [BulkImportPlanItem], whisperModelURL: URL?) async {
        guard isRunning == false, hasFinished == false else { return }
        isRunning = true
        defer {
            isRunning = false
            hasFinished = true
        }

        for item in plan {
            progressByItem[item.id] = BulkImportItemProgress(
                id: item.id,
                baseName: item.baseName,
                status: .running,
                transcriptionProgress: 0
            )

            do {
                try await process(item: item, whisperModelURL: whisperModelURL)
                progressByItem[item.id]?.status = .completed
            } catch {
                progressByItem[item.id]?.status = .failed(error.localizedDescription)
            }
        }
    }

    // Dispatches one plan item to the create-note or attach-audio path based on the URLs
    // present and any matched existing note. Transcription only runs when no text or
    // subtitle source is available for an audio-only item without a matching note.
    private func process(item: BulkImportPlanItem, whisperModelURL: URL?) async throws {
        let textContent = try item.textURL.map { try Self.readText(from: $0) }
        let subtitleData = try item.subtitleURL.map { try Self.readSubtitle(at: $0) }

        if let existingNoteID = item.matchedExistingNoteID, let audioURL = item.audioURL {
            try attachAudioToExistingNote(
                noteID: existingNoteID,
                audioURL: audioURL,
                cues: subtitleData?.cues,
                srtText: subtitleData?.rawText,
                textGridURL: item.textGridURL,
                preferredSubtitleFilename: item.baseName + ".srt"
            )
            return
        }

        // Subtitle-only attach (optionally with TextGrid): user is dropping refreshed
        // cues onto a note they already imported. Audio is untouched; cues, SRT, and
        // any TextGrid checkpoints replace the existing attachment's subtitle data.
        // Without this branch, an SRT-only import would fall through to createNewNote
        // and silently produce a duplicate note instead of updating the existing one.
        if let existingNoteID = item.matchedExistingNoteID,
           item.audioURL == nil,
           let subtitleData {
            try attachSubtitleToExistingNote(
                noteID: existingNoteID,
                cues: subtitleData.cues,
                srtText: subtitleData.rawText,
                textGridURL: item.textGridURL,
                preferredSubtitleFilename: item.baseName + ".srt"
            )
            return
        }

        // TextGrid-only attach: user has the note already (and its cues), just wants to add the
        // karaoke checkpoints. We load the note's existing cues and bind against them — no audio
        // is replaced, no new note created.
        if let existingNoteID = item.matchedExistingNoteID,
           item.audioURL == nil,
           item.subtitleURL == nil,
           item.textURL == nil,
           let textGridURL = item.textGridURL {
            try attachTextGridToExistingNote(noteID: existingNoteID, textGridURL: textGridURL)
            return
        }

        var bodyContent: String? = textContent
        var cues: [SubtitleCue]? = subtitleData?.cues
        var srtText: String? = subtitleData?.rawText

        // Try TextGrid-derived cues BEFORE requiring a Whisper model. A `.TextGrid` shipped
        // alongside an audio file already encodes line boundaries; transcription is only
        // necessary when nothing else supplies cues. Doing this first means MP3 + .TextGrid
        // (no .srt/.txt) succeeds without forcing the user to select a Whisper model — the
        // BulkImportPlanner's requiresTranscription check is updated to match.
        if cues == nil, let textGridURL = item.textGridURL {
            if let derived = try? Self.readDerivedCuesFromTextGrid(at: textGridURL) {
                cues = derived
                bodyContent = bodyContent ?? SubtitleParser.assembleNoteContent(from: derived)
            }
        }

        if bodyContent == nil, cues == nil, let audioURL = item.audioURL {
            guard let modelURL = whisperModelURL else {
                throw BulkImportError.noTranscriptionModel
            }
            let transcribed = try await transcribe(audioURL: audioURL, modelURL: modelURL, itemID: item.id)
            cues = transcribed
            srtText = SubtitleParser.formatSRT(from: transcribed)
            bodyContent = SubtitleParser.assembleNoteContent(from: transcribed)
        }

        if bodyContent == nil, let cues {
            bodyContent = SubtitleParser.assembleNoteContent(from: cues)
        }

        try createNewNote(
            baseName: item.baseName,
            content: bodyContent ?? "",
            audioURL: item.audioURL,
            cues: cues,
            srtText: srtText,
            textGridURL: item.textGridURL
        )
    }

    // Creates a new note from the assembled inputs and saves any audio + subtitle artifacts
    // under a single fresh attachment ID. Skips the attachment write entirely when there is
    // nothing to attach so plain-text imports do not create empty audio entries.
    private func createNewNote(
        baseName: String,
        content: String,
        audioURL: URL?,
        cues: [SubtitleCue]?,
        srtText: String?,
        textGridURL: URL?
    ) throws {
        let title = preferredTitle(baseName: baseName, content: content)
        var attachmentID: UUID? = nil

        if audioURL != nil || cues != nil || srtText != nil {
            let newID = UUID()
            attachmentID = newID

            if let audioURL {
                _ = try NotesAudioStore.shared.saveAudio(from: audioURL, attachmentID: newID)
            }
            if let cues, cues.isEmpty == false {
                try NotesAudioStore.shared.saveCues(cues, attachmentID: newID)
                if let textGridURL,
                   let timings = Self.bindTextGridCheckpoints(textGridURL: textGridURL, cues: cues),
                   timings.isEmpty == false {
                    try NotesAudioStore.shared.saveCueTimings(timings, attachmentID: newID)
                }
            }
            if let srtText, srtText.isEmpty == false {
                _ = try NotesAudioStore.shared.saveSRT(
                    srtText,
                    attachmentID: newID,
                    preferredFilename: baseName + ".srt"
                )
            }
        }

        let note = Note(title: title, content: content, audioAttachmentID: attachmentID)
        store.addNote(note)
    }

    // Attaches audio (and optional subtitle data) to an existing note. Reuses the note's
    // current attachment ID when one is already present so multiple imports overwrite a
    // single audio slot rather than orphaning files in the audio directory.
    private func attachAudioToExistingNote(
        noteID: UUID,
        audioURL: URL,
        cues: [SubtitleCue]?,
        srtText: String?,
        textGridURL: URL?,
        preferredSubtitleFilename: String
    ) throws {
        let attachmentID = store.note(withID: noteID)?.audioAttachmentID ?? UUID()
        _ = try NotesAudioStore.shared.saveAudio(from: audioURL, attachmentID: attachmentID)

        if let cues, cues.isEmpty == false {
            try NotesAudioStore.shared.saveCues(cues, attachmentID: attachmentID)
        }
        // Bind TextGrid checkpoints whenever a .TextGrid is in the import. When the import
        // also carried a fresh .srt the new cues are used; otherwise fall back to the cues
        // already saved on the matched note's attachment — matching the TextGrid-only attach
        // path. Without this fallback, dropping an .audio + .TextGrid pair onto a note that
        // already has saved cues would silently skip binding even though the planner UI
        // labeled the row "with karaoke timings."
        if let textGridURL {
            let cuesForBinding: [SubtitleCue] = {
                if let cues, cues.isEmpty == false { return cues }
                return NotesAudioStore.shared.loadCues(for: attachmentID)
            }()
            if cuesForBinding.isEmpty == false,
               let timings = Self.bindTextGridCheckpoints(textGridURL: textGridURL, cues: cuesForBinding),
               timings.isEmpty == false {
                try NotesAudioStore.shared.saveCueTimings(timings, attachmentID: attachmentID)
            }
        }
        if let srtText, srtText.isEmpty == false {
            _ = try NotesAudioStore.shared.saveSRT(
                srtText,
                attachmentID: attachmentID,
                preferredFilename: preferredSubtitleFilename
            )
        }

        store.updateAudioAttachment(id: noteID, attachmentID: attachmentID)
    }

    // Attaches subtitle data (cues, SRT, optional TextGrid timings) to an existing
    // note's attachment without touching audio. Reuses the note's current attachment
    // ID when present, mirroring attachAudioToExistingNote's behavior, so a later
    // audio import lands on the same attachment slot rather than orphaning files.
    private func attachSubtitleToExistingNote(
        noteID: UUID,
        cues: [SubtitleCue]?,
        srtText: String?,
        textGridURL: URL?,
        preferredSubtitleFilename: String
    ) throws {
        let attachmentID = store.note(withID: noteID)?.audioAttachmentID ?? UUID()

        if let cues, cues.isEmpty == false {
            try NotesAudioStore.shared.saveCues(cues, attachmentID: attachmentID)
        }

        // Bind TextGrid checkpoints against either the freshly-imported cues or, if
        // none were supplied, the cues already saved on the matched note. Mirrors the
        // fallback in attachAudioToExistingNote so a TextGrid in this branch never
        // silently no-ops just because the SRT was the same one already on the note.
        if let textGridURL {
            let cuesForBinding: [SubtitleCue] = {
                if let cues, cues.isEmpty == false { return cues }
                return NotesAudioStore.shared.loadCues(for: attachmentID)
            }()
            if cuesForBinding.isEmpty == false,
               let timings = Self.bindTextGridCheckpoints(textGridURL: textGridURL, cues: cuesForBinding),
               timings.isEmpty == false {
                try NotesAudioStore.shared.saveCueTimings(timings, attachmentID: attachmentID)
            }
        }

        if let srtText, srtText.isEmpty == false {
            _ = try NotesAudioStore.shared.saveSRT(
                srtText,
                attachmentID: attachmentID,
                preferredFilename: preferredSubtitleFilename
            )
        }

        store.updateAudioAttachment(id: noteID, attachmentID: attachmentID)
    }

    // Attaches TextGrid-derived checkpoints to an existing note's attachment.
    // Fails if the note has no attachment or no saved cues — there's nothing to bind against.
    private func attachTextGridToExistingNote(noteID: UUID, textGridURL: URL) throws {
        KaraokeDebugLog.log("bulkAttach: start note=\(noteID.uuidString.prefix(8)) file=\(textGridURL.lastPathComponent)")
        guard let attachmentID = store.note(withID: noteID)?.audioAttachmentID else {
            KaraokeDebugLog.log("bulkAttach: FAIL note has no audio attachment")
            throw BulkImportError.noAttachmentForTextGrid
        }
        let existingCues = NotesAudioStore.shared.loadCues(for: attachmentID)
        KaraokeDebugLog.log("bulkAttach: existingCues=\(existingCues.count) sampleIndices=\(existingCues.prefix(5).map(\.index))")
        guard existingCues.isEmpty == false else {
            KaraokeDebugLog.log("bulkAttach: FAIL existing note has no cues")
            throw BulkImportError.noCuesForTextGrid
        }
        guard let timings = Self.bindTextGridCheckpoints(textGridURL: textGridURL, cues: existingCues),
              timings.isEmpty == false else {
            KaraokeDebugLog.log("bulkAttach: FAIL binder returned 0 checkpoints")
            throw BulkImportError.textGridYieldedNoCheckpoints
        }
        try NotesAudioStore.shared.saveCueTimings(timings, attachmentID: attachmentID)
        KaraokeDebugLog.log("bulkAttach: OK saved timings for attachment=\(attachmentID.uuidString.prefix(8))")
    }

    // Runs Whisper transcription on a single audio file using the supplied model URL,
    // forwarding progress to the matching plan item so the sheet can render per-row state.
    // Returns one SubtitleCue per non-empty Whisper segment, indexed sequentially.
    // nonisolated so the non-Sendable `whisper` instance doesn't cross actor boundaries
    // at the await; progress updates are explicitly hopped to MainActor inside the
    // delegate closure.
    nonisolated private func transcribe(audioURL: URL, modelURL: URL, itemID: String) async throws -> [SubtitleCue] {
        let didStartAudio = audioURL.startAccessingSecurityScopedResource()
        let didStartModel = modelURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAudio { audioURL.stopAccessingSecurityScopedResource() }
            if didStartModel { modelURL.stopAccessingSecurityScopedResource() }
        }

        let audioFrames = try await Self.convertAudioTo16kHzMono(url: audioURL)

        let params = WhisperParams.default
        params.language = .japanese

        let whisper = Whisper(fromFileURL: modelURL, withParams: params)
        let delegate = WhisperTranscriptionDelegate()
        delegate.onProgress = { [weak self] progress in
            Task { @MainActor in
                self?.progressByItem[itemID]?.transcriptionProgress = progress
            }
        }
        whisper.delegate = delegate

        let segments = try await whisper.transcribe(audioFrames: audioFrames)

        var cues: [SubtitleCue] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.isEmpty == false else { continue }
            cues.append(
                SubtitleCue(
                    index: index + 1,
                    startMs: segment.startTime,
                    endMs: segment.endTime,
                    text: text
                )
            )
        }

        if cues.isEmpty {
            throw BulkImportError.transcriptionEmpty
        }
        return cues
    }

    // Computes the note title for new notes. The user's file naming is authoritative — the
    // basename of the imported file always becomes the title. When the basename is empty
    // (rare; would require a file with no name), we fall back to "Untitled" rather than the
    // first content line, so a song's opening lyric never accidentally becomes its title.
    private func preferredTitle(baseName: String, content _: String) -> String {
        let trimmedBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBase.isEmpty ? "Untitled" : trimmedBase
    }

    // Reads a text file from a security-scoped URL, falling back to Latin-1 when the file
    // is not valid UTF-8 so unusual encodings still import without surfacing a hard failure.
    private nonisolated static func readText(from url: URL) throws -> String {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        if let latin = try? String(contentsOf: url, encoding: .isoLatin1) {
            return latin
        }
        throw BulkImportError.unreadableTextFile
    }

    // Reads a subtitle file and returns both its raw text and parsed cues. Both are needed:
    // the cues drive playback and the raw text is persisted so the user can re-export the SRT.
    private nonisolated static func readSubtitle(at url: URL) throws -> (rawText: String, cues: [SubtitleCue]) {
        let rawText = try readText(from: url)
        let cues = SubtitleParser.parse(rawText)
        if cues.isEmpty {
            throw BulkImportError.emptySubtitleFile
        }
        return (rawText, cues)
    }

    // Parses a TextGrid file and binds checkpoints against the supplied cues. Returns nil only
    // when the file is unreadable or unparseable so callers can silently skip — TextGrid is an
    // optional companion, never a hard requirement.
    private nonisolated static func bindTextGridCheckpoints(textGridURL: URL, cues: [SubtitleCue]) -> CueCharTimings? {
        guard let content = try? readText(from: textGridURL) else { return nil }
        guard let document = try? TextGridParser.parse(content) else { return nil }
        return TextGridBinder.bindCheckpoints(document: document, cues: cues)
    }

    // Derives line-level SubtitleCues from a TextGrid's lowest-resolution IntervalTier so a user
    // can import a `.TextGrid`-only bundle (no SRT) and still get a playable note. Lowers through the
    // same TimedTextDocument.lineCues() as the single-import-sheet path so the two can't drift.
    private nonisolated static func readDerivedCuesFromTextGrid(at url: URL) throws -> [SubtitleCue] {
        let raw = try readText(from: url)
        return try TextGridParser.parse(raw).lineCues()
    }

    // Resamples the audio file to 16 kHz mono Float32 PCM via AVAssetReader. Whisper requires
    // this exact format and AVAssetReader handles all common source formats (mp3, wav, m4a, …).
    private nonisolated static func convertAudioTo16kHzMono(url: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else {
                throw BulkImportError.noAudioTrack
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
                throw reader.error ?? BulkImportError.audioReadFailed
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
}

// Errors surfaced as per-item failures in the bulk import sheet.
private enum BulkImportError: LocalizedError {
    case noTranscriptionModel
    case noAudioTrack
    case audioReadFailed
    case unreadableTextFile
    case emptySubtitleFile
    case transcriptionEmpty
    case noAttachmentForTextGrid
    case noCuesForTextGrid
    case textGridYieldedNoCheckpoints

    var errorDescription: String? {
        switch self {
        case .noTranscriptionModel:
            return "Select a Whisper model to transcribe audio without text or subtitles."
        case .noAudioTrack:
            return "The audio file contains no audio track."
        case .audioReadFailed:
            return "Could not read audio data from the file."
        case .unreadableTextFile:
            return "Could not read the text file."
        case .emptySubtitleFile:
            return "The subtitle file contained no cues."
        case .transcriptionEmpty:
            return "Whisper returned no segments — the audio may be silent or the model incompatible."
        case .noAttachmentForTextGrid:
            return "Matching note has no audio attachment to bind karaoke timings to."
        case .noCuesForTextGrid:
            return "Matching note has no subtitle cues to bind karaoke timings against."
        case .textGridYieldedNoCheckpoints:
            return "TextGrid had no intervals that matched the note's cue text."
        }
    }
}
