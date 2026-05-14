import Foundation
import Combine
import SwiftUI

// Caches generated SongBreakdowns keyed by Note ID. Derived data per AGENTS.md — never
// written into Note. On disk as one JSON file per note under Application Support so an
// individual breakdown can be dropped without touching others. In-memory cache builds
// lazily on access so app startup doesn't pay for breakdowns the user isn't studying.
//
// Cache is hash-aware but not auto-invalidating: when the note's current text hash
// disagrees with the stored breakdown's sourceTextHash, callers see `isStale == true`
// and decide whether to surface a Regenerate banner. The old breakdown remains usable
// so a typo edit doesn't silently destroy work.
@MainActor
final class SongBreakdownStore: ObservableObject {

    // Publishes the in-memory cache. Views observe this to react when a breakdown lands or
    // gets cleared. May be sparse — a missing entry could be "never generated" or "on disk
    // but not yet faulted in"; use `hasBreakdownOnDisk` for the latter distinction.
    @Published private(set) var breakdownsByNoteID: [UUID: SongBreakdown] = [:]

    private let directoryURL: URL
    private let fileManager: FileManager
    private var knownNoteIDsOnDisk: Set<UUID> = []

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = SongBreakdownStore.applicationSupportDirectory(fileManager: fileManager)
        self.directoryURL = base.appendingPathComponent("SongBreakdowns", isDirectory: true)
        ensureDirectoryExists()
        self.knownNoteIDsOnDisk = scanDirectoryForNoteIDs()
    }

    // Returns the cached breakdown for the note, faulting in from disk if needed. Returns nil
    // when no breakdown has ever been generated (or the on-disk file is corrupt).
    func breakdown(forNoteID id: UUID) -> SongBreakdown? {
        if let cached = breakdownsByNoteID[id] {
            return cached
        }
        guard knownNoteIDsOnDisk.contains(id) else { return nil }
        guard let loaded = readFromDisk(noteID: id) else {
            knownNoteIDsOnDisk.remove(id)
            return nil
        }
        breakdownsByNoteID[id] = loaded
        return loaded
    }

    // Returns true when a breakdown exists (in cache or on disk) and its sourceTextHash
    // disagrees with `currentTextHash` — i.e. the note text changed since generation.
    // Used to drive the "lyrics changed since generation" banner.
    func isStale(forNoteID id: UUID, currentTextHash: String) -> Bool {
        guard let existing = breakdown(forNoteID: id) else { return false }
        return existing.sourceTextHash != currentTextHash
    }

    // Returns true when a fresh breakdown exists matching the current text hash.
    func hasFreshBreakdown(forNoteID id: UUID, currentTextHash: String) -> Bool {
        guard let existing = breakdown(forNoteID: id) else { return false }
        return existing.sourceTextHash == currentTextHash
    }

    // Replaces (or installs) the breakdown for a note. Encodes synchronously on the main
    // actor (JSON is tiny — under 100 KB even for long songs) so the Codable conformance
    // stays in its inferred isolation; only the file I/O is detached so UI doesn't block.
    func setBreakdown(_ breakdown: SongBreakdown) {
        breakdownsByNoteID[breakdown.noteID] = breakdown
        knownNoteIDsOnDisk.insert(breakdown.noteID)
        let url = fileURL(for: breakdown.noteID)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(breakdown)
        } catch {
            print("[SongBreakdownStore] encode failed for \(breakdown.noteID): \(error)")
            return
        }

        let directory = directoryURL
        let manager = fileManager
        Task.detached(priority: .utility) {
            if manager.fileExists(atPath: directory.path) == false {
                try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try? data.write(to: url, options: .atomic)
        }
    }

    // Removes the breakdown for a note. Used by the Regenerate flow before invoking the
    // service so the cache reflects "nothing here" while the new call is in flight.
    func clearBreakdown(forNoteID id: UUID) {
        breakdownsByNoteID.removeValue(forKey: id)
        knownNoteIDsOnDisk.remove(id)
        let url = fileURL(for: id)
        Task.detached(priority: .utility) { [fileManager] in
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Disk

    // Constructs the per-note JSON file URL so the cache layout stays predictable and
    // inspectable when debugging which notes have generated breakdowns.
    private func fileURL(for noteID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(noteID.uuidString).json", isDirectory: false)
    }

    // Creates the cache directory on first use. Tolerant of failure: missing-dir errors are
    // surfaced to the console and the store falls back to read-miss / write-retry behaviour.
    private func ensureDirectoryExists() {
        guard fileManager.fileExists(atPath: directoryURL.path) == false else { return }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            // Directory creation failure is recoverable — reads will fall through to nil and
            // writes will retry. Surface to console; do not crash the app.
            print("[SongBreakdownStore] could not create directory: \(error)")
        }
    }

    // Lists existing files in the directory and parses their basenames as UUIDs so the store
    // knows which notes have on-disk breakdowns without paying for full JSON decoding.
    private func scanDirectoryForNoteIDs() -> Set<UUID> {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let contents = (try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        var ids: Set<UUID> = []
        for url in contents where url.pathExtension == "json" {
            let basename = url.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: basename) {
                ids.insert(id)
            }
        }
        return ids
    }

    // Loads a breakdown from disk on first access. Returns nil on missing file or decode
    // failure so the caller can fall through to "never generated" without crashing.
    private func readFromDisk(noteID: UUID) -> SongBreakdown? {
        let url = fileURL(for: noteID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SongBreakdown.self, from: data)
    }

    // Builds the per-app Application Support root. SwiftUI's @StateObject and the existing
    // stores rely on the same conventional location, so this keeps the breakdown cache near
    // other derived data (audio attachments, lyric translations).
    nonisolated private static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        if let url = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return url
        }
        // Fallback to a temp directory so the app degrades gracefully on a permission failure.
        return fileManager.temporaryDirectory
    }
}
