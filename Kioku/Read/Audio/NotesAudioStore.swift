import Foundation

// Manages audio files and subtitle cue data on disk under the app's Documents/audio directory.
// Each attachment is keyed by a UUID shared between the Note model and the stored files.
final class NotesAudioStore {
    // Shared instance so both NotesView (import) and ReadView (playback) access the same storage.
    static let shared = NotesAudioStore(audioDirectory: NotesAudioStore.defaultAudioDirectory())

    private let audioDirectory: URL

    // Designated initializer. The base directory is parameterized so tests can scope each
    // case to a temp dir without polluting Documents/. Production wiring goes through `.shared`.
    init(audioDirectory: URL) {
        self.audioDirectory = audioDirectory
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    // Resolves the production audio directory at `Documents/audio`. Kept as a static helper
    // so the singleton can use it without duplicating the path logic at the call site.
    private static func defaultAudioDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("audio", isDirectory: true)
    }

    // Copies an audio file from a security-scoped URL into permanent storage.
    // Returns the stored destination URL.
    func saveAudio(from sourceURL: URL, attachmentID: UUID) throws -> URL {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
        let destination = audioDirectory.appendingPathComponent(
            storedFilename(
                attachmentID: attachmentID,
                originalFilename: sourceURL.lastPathComponent,
                fallbackExtension: ext
            )
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    // Persists the subtitle cue list for an attachment as JSON.
    func saveCues(_ cues: [SubtitleCue], attachmentID: UUID) throws {
        let destination = audioDirectory.appendingPathComponent(attachmentID.uuidString + ".cues.json")
        let data = try JSONEncoder().encode(cues)
        try data.write(to: destination, options: .atomic)
    }

    // Persists the TextGrid-derived per-cue character checkpoints for an attachment.
    // Absence of the file is the canonical "no karaoke data" signal — readers must treat the
    // missing file as a normal empty case, not an error. Empty input removes any existing file.
    func saveCueTimings(_ timings: CueCharTimings, attachmentID: UUID) throws {
        let destination = cueTimingsURL(for: attachmentID)
        if timings.isEmpty {
            try? FileManager.default.removeItem(at: destination)
            KaraokeDebugLog.log("saveCueTimings: empty → removed file for attachment=\(attachmentID.uuidString.prefix(8))")
            return
        }
        let data = try JSONEncoder().encode(timings)
        try data.write(to: destination, options: .atomic)
        let total = timings.values.reduce(0) { $0 + $1.count }
        KaraokeDebugLog.log("saveCueTimings: wrote \(total) checkpoints across \(timings.count) cues for attachment=\(attachmentID.uuidString.prefix(8))")
    }

    // Loads checkpoints for an attachment, returning empty on any failure or missing file.
    func loadCueTimings(for attachmentID: UUID) -> CueCharTimings {
        let source = cueTimingsURL(for: attachmentID)
        guard
            let data = try? Data(contentsOf: source),
            let timings = try? JSONDecoder().decode(CueCharTimings.self, from: data)
        else {
            KaraokeDebugLog.log("loadCueTimings: empty (no file or decode failed) for attachment=\(attachmentID.uuidString.prefix(8))")
            return [:]
        }
        let total = timings.values.reduce(0) { $0 + $1.count }
        KaraokeDebugLog.log("loadCueTimings: \(total) checkpoints across \(timings.count) cues for attachment=\(attachmentID.uuidString.prefix(8))")
        return timings
    }

    // URL where the timings JSON is stored alongside cues for an attachment.
    func cueTimingsURL(for attachmentID: UUID) -> URL {
        audioDirectory.appendingPathComponent(attachmentID.uuidString + ".timings.json")
    }

    // Persists the raw SRT response for one attachment so it can be copied or exported later.
    func saveSRT(_ srtText: String, attachmentID: UUID, preferredFilename: String? = nil) throws -> URL {
        if let existingURL = subtitleURL(for: attachmentID) {
            try? FileManager.default.removeItem(at: existingURL)
        }

        let destination = audioDirectory.appendingPathComponent(
            storedFilename(
                attachmentID: attachmentID,
                originalFilename: preferredFilename ?? "\(attachmentID.uuidString).srt",
                fallbackExtension: "srt"
            )
        )
        try Data(srtText.utf8).write(to: destination, options: .atomic)
        return destination
    }

    // Returns the URL of the stored audio file, trying common extensions.
    func audioURL(for attachmentID: UUID) -> URL? {
        let extensions = ["mp3", "m4a", "aac", "wav", "caf"]
        if let storedURL = storedFileURL(for: attachmentID, allowedExtensions: extensions) {
            return storedURL
        }

        let legacyBase = audioDirectory.appendingPathComponent(attachmentID.uuidString)
        return extensions
            .map { legacyBase.appendingPathExtension($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // Loads and decodes the subtitle cues for an attachment. Returns empty array on any failure.
    func loadCues(for attachmentID: UUID) -> [SubtitleCue] {
        let source = audioDirectory.appendingPathComponent(attachmentID.uuidString + ".cues.json")
        guard
            let data = try? Data(contentsOf: source),
            let cues = try? JSONDecoder().decode([SubtitleCue].self, from: data)
        else {
            return []
        }
        return cues
    }

    // Returns the saved raw SRT file URL when one exists.
    func subtitleURL(for attachmentID: UUID) -> URL? {
        if let storedURL = storedFileURL(for: attachmentID, allowedExtensions: ["srt"]) {
            return storedURL
        }

        let legacyURL = audioDirectory.appendingPathComponent(attachmentID.uuidString).appendingPathExtension("srt")
        return FileManager.default.fileExists(atPath: legacyURL.path) ? legacyURL : nil
    }

    // Reads all files for one attachment and returns a backup snapshot.
    // Returns nil if no audio file exists for the attachment (nothing to back up).
    func exportAttachment(for attachmentID: UUID) -> AudioAttachmentBackup? {
        guard let audioURL = audioURL(for: attachmentID) else { return nil }
        guard let audioData = try? Data(contentsOf: audioURL) else { return nil }
        let srtText = loadSRT(for: attachmentID)
        let cues = loadCues(for: attachmentID)
        let timings = loadCueTimings(for: attachmentID)
        return AudioAttachmentBackup(
            attachmentID: attachmentID,
            audioFilename: readableFilename(fromStoredURL: audioURL, defaultExtension: audioURL.pathExtension),
            audioData: audioData,
            srtText: srtText,
            cues: cues.isEmpty ? nil : cues,
            timings: timings.isEmpty ? nil : timings
        )
    }

    // Writes the audio file, SRT, and cues from a backup snapshot back to disk.
    // Safe to call multiple times — existing files are overwritten.
    func importAttachment(_ backup: AudioAttachmentBackup) throws {
        let ext = (backup.audioFilename as NSString).pathExtension
        let destination = audioDirectory.appendingPathComponent(
            storedFilename(
                attachmentID: backup.attachmentID,
                originalFilename: backup.audioFilename,
                fallbackExtension: ext.isEmpty ? "mp3" : ext
            )
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try backup.audioData.write(to: destination, options: .atomic)

        if let srtText = backup.srtText {
            // Derive the SRT filename from the audio basename via the dedicated helper.
            // Passing backup.audioFilename ("song.mp3") directly would propagate the audio
            // extension through storedFilename and write the SRT to "{uuid}-song.mp3",
            // overwriting the audio we just restored. Pinned by
            // NotesAudioStoreTests.testImportAttachmentWithAudioAndSRTKeepsBothIntact.
            let srtFilename = Self.preferredSubtitleFilename(forAudioFilename: backup.audioFilename)
            _ = try saveSRT(srtText, attachmentID: backup.attachmentID, preferredFilename: srtFilename)
        }

        if let cues = backup.cues {
            try saveCues(cues, attachmentID: backup.attachmentID)
        }

        // Always invoke saveCueTimings — when the backup carries no timings it removes any
        // stale .timings.json on disk. Without this, restoring an older backup over an
        // attachment that has karaoke checkpoints would leave the previous file in place
        // and loadCueTimings would keep returning the old data.
        try saveCueTimings(backup.timings ?? [:], attachmentID: backup.attachmentID)
    }

    // Loads the saved raw SRT text when present.
    func loadSRT(for attachmentID: UUID) -> String? {
        guard let subtitleURL = subtitleURL(for: attachmentID) else { return nil }
        guard let data = try? Data(contentsOf: subtitleURL) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Returns the original audio file's basename (no extension) so callers can match a stored
    // attachment against an externally-supplied filename (e.g., a TextGrid sibling for the same song).
    // Returns nil when no audio file is stored for the attachment.
    func audioBaseName(for attachmentID: UUID) -> String? {
        guard let url = audioURL(for: attachmentID) else { return nil }
        let restored = readableFilename(fromStoredURL: url, defaultExtension: url.pathExtension)
        return (restored as NSString).deletingPathExtension
    }

    // Produces the preferred user-facing export filename for one attachment's subtitle file.
    func preferredSubtitleExportFilename(for attachmentID: UUID) -> String {
        if let subtitleURL = subtitleURL(for: attachmentID) {
            return readableFilename(fromStoredURL: subtitleURL, defaultExtension: "srt")
        }
        if let audioURL = audioURL(for: attachmentID) {
            let audioBase = readableFilename(fromStoredURL: audioURL, defaultExtension: audioURL.pathExtension)
                .replacingOccurrences(of: ".\(audioURL.pathExtension)", with: "")
            return audioBase + ".srt"
        }
        return attachmentID.uuidString + ".srt"
    }

    // Derives the default subtitle filename from an audio filename so paired files are easy to identify.
    static func preferredSubtitleFilename(forAudioFilename audioFilename: String) -> String {
        let trimmed = audioFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "subtitles.srt"
        }

        let base = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        return (base.isEmpty ? "subtitles" : base) + ".srt"
    }

    // Removes all files associated with an attachment to keep storage clean after note deletion.
    func deleteAttachment(_ attachmentID: UUID) {
        let managedExtensions = ["mp3", "m4a", "aac", "wav", "caf", "srt"]
        if let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        ) {
            for url in fileURLs where matchesAttachmentID(url, attachmentID: attachmentID, allowedExtensions: managedExtensions) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let legacyBase = audioDirectory.appendingPathComponent(attachmentID.uuidString)
        for ext in managedExtensions {
            try? FileManager.default.removeItem(at: legacyBase.appendingPathExtension(ext))
        }

        try? FileManager.default.removeItem(
            at: audioDirectory.appendingPathComponent(attachmentID.uuidString + ".cues.json")
        )
        try? FileManager.default.removeItem(at: cueTimingsURL(for: attachmentID))

        // Clean up translation cache when the attachment is deleted
        UserDefaults.standard.removeObject(forKey: "kioku.lyricsTranslations.\(attachmentID.uuidString)")
    }

    // Searches the audio directory for the first file that matches the attachment ID and an allowed extension.
    private func storedFileURL(for attachmentID: UUID, allowedExtensions: [String]) -> URL? {
        let allowed = Set(allowedExtensions.map { $0.lowercased() })
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return fileURLs.first { matchesAttachmentID($0, attachmentID: attachmentID, allowedExtensions: allowed) }
    }

    // Convenience overload that converts the array to a Set before delegating to the core implementation.
    private func matchesAttachmentID(_ url: URL, attachmentID: UUID, allowedExtensions: [String]) -> Bool {
        matchesAttachmentID(url, attachmentID: attachmentID, allowedExtensions: Set(allowedExtensions.map { $0.lowercased() }))
    }

    // Checks that a file URL belongs to a given attachment by comparing the stem against the UUID prefix pattern.
    private func matchesAttachmentID(_ url: URL, attachmentID: UUID, allowedExtensions: Set<String>) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            return false
        }

        let filename = url.deletingPathExtension().lastPathComponent
        return filename == attachmentID.uuidString || filename.hasPrefix(attachmentID.uuidString + "-")
    }

    // Constructs the on-disk filename by prepending the attachment UUID so files are scoped to their note.
    private func storedFilename(attachmentID: UUID, originalFilename: String, fallbackExtension: String) -> String {
        let ext = originalFilename.pathExtension.isEmpty ? fallbackExtension : originalFilename.pathExtension
        let base = sanitizeFilenameComponent(originalFilename.deletingPathExtension)
        if base.isEmpty {
            return attachmentID.uuidString + "." + ext
        }
        return attachmentID.uuidString + "-" + base + "." + ext
    }

    // Reverses the UUID-prefix storage scheme to recover the human-readable original filename.
    // storedFilename writes either "{uuid}.ext" (no preserved basename) or "{uuid}-{base}.ext".
    // UUIDs are exactly 36 chars with 4 internal hyphens, so splitting the stem on the first
    // hyphen would lose UUID segments into what should be the base — the prefix has to be
    // detected by fixed length + UUID validity. Pinned by
    // NotesAudioStoreTests.testPreferredSubtitleExportFilenameUsesSRTBasenameWhenPresent.
    private func readableFilename(fromStoredURL url: URL, defaultExtension: String) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? defaultExtension : url.pathExtension
        let uuidLength = 36
        guard stem.count >= uuidLength + 2 else {
            return url.lastPathComponent
        }
        let uuidEnd = stem.index(stem.startIndex, offsetBy: uuidLength)
        guard
            UUID(uuidString: String(stem[..<uuidEnd])) != nil,
            stem[uuidEnd] == "-"
        else {
            return url.lastPathComponent
        }
        let baseStart = stem.index(after: uuidEnd)
        return String(stem[baseStart...]) + "." + ext
    }

    // Strips characters that are unsafe in filenames so stored audio files open without escaping issues.
    private func sanitizeFilenameComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ""
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mappedScalars = trimmed.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(mappedScalars)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized
    }
}

private extension String {
    var pathExtension: String {
        (self as NSString).pathExtension
    }

    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }
}
