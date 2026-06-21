import Foundation
import Darwin   // clonefile — APFS copy-on-write so duplicate songs don't duplicate bytes

// Manages audio files and subtitle cue data on disk under the app's Documents/audio directory.
// Each attachment is keyed by a UUID shared between the Note model and the stored files.
final class NotesAudioStore: NotesAttachmentDeleting {
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

        // De-dup: if this exact audio is already stored (the same song on another attachment), clone
        // the existing copy — APFS copy-on-write shares the data blocks, so the duplicate costs ~0
        // disk. Per-file deletion still works (the OS ref-counts blocks). Falls back to a real copy
        // when there's no twin or cloning isn't supported.
        if let twin = existingStoredTwin(ofSourceURL: sourceURL),
           Self.cloneFile(at: twin, to: destination) {
            return destination
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    // Finds an already-stored audio file with byte-identical content to `sourceURL`, if any.
    // `contentsEqual` compares size before bytes, so this stays cheap across a library.
    private func existingStoredTwin(ofSourceURL sourceURL: URL) -> URL? {
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "caf"]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first {
            audioExts.contains($0.pathExtension.lowercased())
                && FileManager.default.contentsEqual(atPath: sourceURL.path, andPath: $0.path)
        }
    }

    // APFS copy-on-write clone: `destination` shares `source`'s data blocks until either is modified
    // (audio never is), so it adds no real disk. Returns false when cloning isn't possible (non-APFS,
    // cross-volume) so the caller can fall back to a plain copy. Destination must not already exist.
    @discardableResult
    static func cloneFile(at source: URL, to destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                guard let src, let dst else { return false }
                // COPYFILE_CLONE clones (copy-on-write) when the filesystem supports it and falls
                // back to a plain copy otherwise. copyfile() lives in libSystem and is always
                // bound at load — unlike a bare clonefile() reference, which can fail dyld linkage.
                return copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0
            }
        }
    }

    // One-time sweep folding already-stored duplicate audio (the same song attached more than once
    // before de-dup existed) into APFS clones of a single canonical copy, reclaiming wasted disk.
    // Byte-identical only; each duplicate is atomically replaced by a clone of its canonical twin
    // (same filename, shared blocks — attachments still resolve by UUID prefix). Runs once.
    func dedupeStoredAudio() {
        let flag = "kioku.migration.dedupedAudioV1"
        guard UserDefaults.standard.bool(forKey: flag) == false else { return }
        defer { UserDefaults.standard.set(true, forKey: flag) }
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "caf"]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }
        var bySize: [Int: [URL]] = [:]
        for f in files where audioExts.contains(f.pathExtension.lowercased()) {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            bySize[size, default: []].append(f)
        }
        for (_, group) in bySize where group.count > 1 {
            for i in 1..<group.count {
                let dup = group[i]
                guard let canonical = group[0..<i].first(where: {
                    FileManager.default.contentsEqual(atPath: $0.path, andPath: dup.path)
                }) else { continue }
                let tmp = audioDirectory.appendingPathComponent("\(UUID().uuidString).declone")
                guard Self.cloneFile(at: canonical, to: tmp) else {
                    try? FileManager.default.removeItem(at: tmp); continue
                }
                // Atomic swap: replace the duplicate with its byte-identical clone.
                if (try? FileManager.default.replaceItemAt(dup, withItemAt: tmp)) == nil {
                    try? FileManager.default.removeItem(at: tmp)
                }
            }
        }
    }

    // Persists the subtitle cue list for an attachment as JSON.
    func saveCues(_ cues: [SubtitleCue], attachmentID: UUID) throws {
        let destination = audioDirectory.appendingPathComponent(attachmentID.uuidString + ".cues.json")
        let data = try JSONEncoder().encode(cues)
        try data.write(to: destination, options: .atomic)
    }

    // Whether an attachment has saved subtitle cues. This is the single persisted truth for
    // "has subtitles" now that the .srt sidecar is gone (SRT is an export-only projection of
    // cues.json) — replaces the former `subtitleURL(for:) != nil` probe.
    func hasCues(for attachmentID: UUID) -> Bool {
        loadCues(for: attachmentID).isEmpty == false
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

    // Loads and decodes the subtitle cues (with their inline checkpoints) for an attachment.
    // Returns empty array on any failure.
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

    // One-time sweep removing every legacy .srt sidecar from the audio container. The .srt was
    // demoted to an export-only projection of cues.json (the single source of truth); nothing reads
    // a stored .srt anymore, so these files are inert. A UserDefaults flag makes it run exactly once.
    func purgeLegacySRTSidecars() {
        let flag = "kioku.migration.purgedSRTSidecars"
        guard UserDefaults.standard.bool(forKey: flag) == false else { return }
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory, includingPropertiesForKeys: nil
        ) {
            for url in urls where url.pathExtension.lowercased() == "srt" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    // Reads all files for one attachment and returns a backup snapshot.
    // Returns nil if no audio file exists for the attachment (nothing to back up).
    func exportAttachment(for attachmentID: UUID) -> AudioAttachmentBackup? {
        guard let audioURL = audioURL(for: attachmentID) else { return nil }
        guard let audioData = try? Data(contentsOf: audioURL) else { return nil }
        // Cues carry their checkpoints inline and are the single source of truth, so the backup
        // needs only the cue list. The SRT is regenerated from those cues purely so an older app
        // version (which restored a .srt sidecar) can still decode this backup; `timings` stays nil
        // and exists solely to decode old backups.
        let cues = loadCues(for: attachmentID)
        let srtText = cues.isEmpty ? nil : SubtitleParser.formatSRT(from: cues)
        return AudioAttachmentBackup(
            attachmentID: attachmentID,
            audioFilename: readableFilename(fromStoredURL: audioURL, defaultExtension: audioURL.pathExtension),
            audioData: audioData,
            srtText: srtText,
            cues: cues.isEmpty ? nil : cues
        )
    }

    // Writes the audio file and cues from a backup snapshot back to disk.
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

        // cues.json is the only persisted truth — no .srt sidecar is written. Prefer the backup's
        // cues; fall back to parsing its (legacy) SRT text so an old cues-less backup still restores.
        if let cues = backup.cues {
            try saveCues(cues, attachmentID: backup.attachmentID)
        } else if let srtText = backup.srtText {
            let parsed = SubtitleParser.parse(srtText)
            if parsed.isEmpty == false {
                try saveCues(parsed, attachmentID: backup.attachmentID)
            }
        }
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
    // Derived from the audio basename — there's no stored .srt to read a name from anymore (SRT is
    // generated on export). Falls back to the attachment UUID when no audio is present.
    func preferredSubtitleExportFilename(for attachmentID: UUID) -> String {
        if let audioURL = audioURL(for: attachmentID) {
            let audioFilename = readableFilename(fromStoredURL: audioURL, defaultExtension: audioURL.pathExtension)
            return Self.preferredSubtitleFilename(forAudioFilename: audioFilename)
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

        // Clean up translation cache when the attachment is deleted.
        // Both the legacy index-keyed entry and the current text-keyed entry must go,
        // otherwise per-attachment translations accumulate in UserDefaults forever.
        UserDefaults.standard.removeObject(forKey: "kioku.lyricsTranslations.\(attachmentID.uuidString)")
        UserDefaults.standard.removeObject(forKey: "kioku.lyricsTranslationsByText.\(attachmentID.uuidString)")
    }

    // Removes every stored attachment file and all persisted translation caches.
    // Supports "Reset All Data": orphaned files with no surviving note reference
    // would otherwise survive a store-level reset.
    func deleteAllStoredFiles() {
        if let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        ) {
            for url in fileURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("kioku.lyricsTranslations.") || key.hasPrefix("kioku.lyricsTranslationsByText.") {
            defaults.removeObject(forKey: key)
        }
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
