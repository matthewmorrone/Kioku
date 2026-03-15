import Foundation

// Manages audio files and subtitle cue data on disk under the app's Documents/audio directory.
// Each attachment is keyed by a UUID shared between the Note model and the stored files.
final class NoteAudioStore {
    // Shared instance so both NotesView (import) and ReadView (playback) access the same storage.
    static let shared = NoteAudioStore()

    private let audioDirectory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        audioDirectory = docs.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    // Copies an audio file from a security-scoped URL into permanent storage.
    // Returns the stored destination URL.
    func saveAudio(from sourceURL: URL, attachmentID: UUID) throws -> URL {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
        let destination = audioDirectory
            .appendingPathComponent(attachmentID.uuidString)
            .appendingPathExtension(ext)

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

    // Returns the URL of the stored audio file, trying common extensions.
    func audioURL(for attachmentID: UUID) -> URL? {
        let base = audioDirectory.appendingPathComponent(attachmentID.uuidString)
        let extensions = ["mp3", "m4a", "aac", "wav", "caf"]
        return extensions
            .map { base.appendingPathExtension($0) }
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

    // Removes all files associated with an attachment to keep storage clean after note deletion.
    func deleteAttachment(_ attachmentID: UUID) {
        let base = audioDirectory.appendingPathComponent(attachmentID.uuidString)
        let extensions = ["mp3", "m4a", "aac", "wav", "caf"]
        for ext in extensions {
            try? FileManager.default.removeItem(at: base.appendingPathExtension(ext))
        }
        try? FileManager.default.removeItem(
            at: audioDirectory.appendingPathComponent(attachmentID.uuidString + ".cues.json")
        )
    }
}
