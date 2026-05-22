import Foundation
import Combine
import SwiftUI

// Caches generated SongBreakdowns keyed by Note ID. Derived data per AGENTS.md — never
// written into Note. On disk as one JSON file per note under Application Support so an
// individual breakdown can be dropped without touching others.
//
// Two in-memory tiers:
//   1. `breakdownsByNoteID` — @Published, owned by user-driven set/clear operations.
//   2. `diskMemoCache` — non-published memo populated by lazy disk reads on access.
//
// The split exists so the read accessor can fault a disk-backed breakdown into memory
// during SwiftUI body evaluation (SongsHomeView rows do this on relaunch) without
// triggering `objectWillChange` mid-render, which produces SwiftUI's "Publishing changes
// from within view updates" runtime warning and can destabilise row diffing.
//
// Cache is hash-aware but not auto-invalidating: when the note's current text hash
// disagrees with the stored breakdown's sourceTextHash, callers see `isStale == true`
// and decide whether to surface a Regenerate banner. The old breakdown remains usable
// so a typo edit doesn't silently destroy work.
@MainActor
final class SongBreakdownStore: ObservableObject {

    // Publishes only entries written via set/clear — i.e. user-initiated changes since
    // launch. Views observe this to react to generations and regenerations. May be sparse
    // (a disk-backed entry isn't published until/unless something writes to it).
    @Published private(set) var breakdownsByNoteID: [UUID: SongBreakdown] = [:]

    // In-flight / failed generation state, keyed by Note ID. Lives here (not in the view)
    // so dismissing the breakdown sheet doesn't tear down the running URLSession task;
    // re-entering the sheet picks the same state back up and the user sees a still-running
    // spinner or the last error verbatim. See `startGeneration(forNoteID:lyrics:)`.
    @Published private(set) var generationStateByNoteID: [UUID: SongBreakdownGenerationState] = [:]

    // Non-published memo for lazy disk reads. Mutated by `breakdown(forNoteID:)` so the
    // accessor stays safe to call during SwiftUI body evaluation — the field is not
    // observed, so the mutation doesn't invalidate views.
    private var diskMemoCache: [UUID: SongBreakdown] = [:]

    // Hold strong refs to running Tasks. Erasing the entry on completion is enough — the
    // Task type wraps a structured-concurrency handle, not a cancellation channel, so the
    // task continues until either it finishes naturally or `cancelGeneration` calls cancel.
    private var generationTasksByNoteID: [UUID: Task<Void, Never>] = [:]

    // One URLSession (inside the service) is reused across notes so we don't open a fresh
    // long-timeout session per generate call. Injectable for tests.
    private let service: SongBreakdownService

    private let directoryURL: URL
    private let fileManager: FileManager
    private var knownNoteIDsOnDisk: Set<UUID> = []

    // `service` is optional/injected rather than a default arg so the default construction
    // runs inside this @MainActor init body — the SongBreakdownService initializer is
    // (transitively) main-actor-isolated and evaluating it as a default argument at the
    // caller's nonisolated context produces a strict-concurrency warning.
    init(fileManager: FileManager = .default, service: SongBreakdownService? = nil) {
        self.fileManager = fileManager
        self.service = service ?? SongBreakdownService()
        let base = SongBreakdownStore.applicationSupportDirectory(fileManager: fileManager)
        self.directoryURL = base.appendingPathComponent("SongBreakdowns", isDirectory: true)
        ensureDirectoryExists()
        self.knownNoteIDsOnDisk = scanDirectoryForNoteIDs()
    }

    // Returns the cached breakdown for the note. Looks in the @Published cache first, then
    // the non-published memo, then disk (faulting into memo on hit). Never mutates the
    // @Published cache so it can be called from SwiftUI view bodies without producing the
    // "publishing changes from within view updates" warning.
    //
    // Self-heal: any value pulled from disk goes through `SongBreakdownRecovery` before it
    // lands in the memo. Breakdowns produced by the pre-fix parser had the whole song
    // collapsed into line 1; recovery splits the leaked headers back out and re-buckets the
    // vocabulary against each line's text. Healed values are persisted back so the next
    // read skips recovery entirely.
    func breakdown(forNoteID id: UUID) -> SongBreakdown? {
        if let published = breakdownsByNoteID[id] {
            return published
        }
        if let memo = diskMemoCache[id] {
            return memo
        }
        guard knownNoteIDsOnDisk.contains(id) else { return nil }
        guard let loaded = readFromDisk(noteID: id) else {
            knownNoteIDsOnDisk.remove(id)
            return nil
        }
        let healed = SongBreakdownRecovery.recoverIfNeeded(loaded)
        diskMemoCache[id] = healed
        if healed != loaded {
            writeToDisk(healed)
        }
        return healed
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

    // Replaces (or installs) the breakdown for a note. Writes synchronously: a regenerate
    // flow calls clearBreakdown then immediately setBreakdown, so any background-scheduled
    // delete would race with the new write and could wipe fresh JSON before relaunch.
    // JSON for a typical breakdown is well under 100 KB; the main-thread cost is negligible.
    func setBreakdown(_ breakdown: SongBreakdown) {
        diskMemoCache.removeValue(forKey: breakdown.noteID)
        breakdownsByNoteID[breakdown.noteID] = breakdown
        knownNoteIDsOnDisk.insert(breakdown.noteID)
        writeToDisk(breakdown)
    }

    // Quietly persists a breakdown to disk without touching `breakdownsByNoteID`. Used by
    // the recovery writeback so a self-heal during a SwiftUI body evaluation doesn't trip
    // the "publishing changes from within view updates" runtime warning. setBreakdown
    // mutates the published cache itself, then calls this to flush.
    private func writeToDisk(_ breakdown: SongBreakdown) {
        let url = fileURL(for: breakdown.noteID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(breakdown)
            if fileManager.fileExists(atPath: directoryURL.path) == false {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            print("[SongBreakdownStore] write failed for \(breakdown.noteID): \(error)")
        }
    }

    // Removes the breakdown for a note. Synchronous on disk so a follow-up setBreakdown
    // (Regenerate flow) cannot race a still-pending delete and have its fresh JSON wiped.
    func clearBreakdown(forNoteID id: UUID) {
        breakdownsByNoteID.removeValue(forKey: id)
        diskMemoCache.removeValue(forKey: id)
        knownNoteIDsOnDisk.remove(id)

        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                print("[SongBreakdownStore] delete failed for \(id): \(error)")
            }
        }
    }

    // MARK: - Background generation

    // Returns true while there's an in-flight (running) generation Task for the note.
    // Distinct from "is `failed`" — a failure remains in `generationStateByNoteID` until
    // explicitly cleared (Retry or sheet dismiss), but no Task is associated with it.
    func isGenerating(forNoteID id: UUID) -> Bool {
        if case .running = generationStateByNoteID[id] { return true }
        return false
    }

    // Kicks off a background generation. Idempotent on the noteID: if a Task is already
    // running for this note, returns without scheduling another so two simultaneous taps
    // (or a re-mount of the sheet) don't double-bill the user. The Task is owned by the
    // store, not by the calling view — dismissing the sheet does not cancel it.
    //
    // `providerLabel` is supplied by the caller so the loading view can show "via Claude"
    // / "via OpenAI" / "stub mode" using the same lookup it would have used inline. It is
    // a UI-only label and has no effect on dispatch.
    func startGeneration(forNoteID id: UUID, lyrics: String, providerLabel: String) {
        if generationTasksByNoteID[id] != nil { return }
        generationStateByNoteID[id] = .running(startedAt: Date(), providerLabel: providerLabel)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let breakdown = try await self.service.generate(noteID: id, lyrics: lyrics)
                try Task.checkCancellation()
                self.setBreakdown(breakdown)
                self.generationStateByNoteID.removeValue(forKey: id)
            } catch is CancellationError {
                self.generationStateByNoteID.removeValue(forKey: id)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.generationStateByNoteID[id] = .failed(message: message)
            }
            self.generationTasksByNoteID.removeValue(forKey: id)
        }
        generationTasksByNoteID[id] = task
    }

    // Cancels the in-flight Task for the note (no-op if there isn't one) and clears any
    // running/failed state. Used by the explicit Cancel button in the loading view. Note:
    // dismissing the sheet does NOT invoke this — that's the whole point of moving the
    // Task here.
    func cancelGeneration(forNoteID id: UUID) {
        generationTasksByNoteID[id]?.cancel()
        generationTasksByNoteID.removeValue(forKey: id)
        generationStateByNoteID.removeValue(forKey: id)
    }

    // Clears a `.failed` entry without affecting any running task. Lets the Retry button
    // transition the view back to the prompt/loading screen before re-firing the call.
    func clearGenerationError(forNoteID id: UUID) {
        if case .failed = generationStateByNoteID[id] {
            generationStateByNoteID.removeValue(forKey: id)
        }
    }

    // UI-only label resolution. Lives on the store so views and tests share one lookup
    // instead of each surface re-deriving the same UserDefaults read. Reflects the same
    // useLLM / activeProvider decision the service will make at dispatch time.
    static func loadingProviderLabel() -> String {
        let useLLM = UserDefaults.standard.bool(forKey: LLMSettings.useLLMKey)
        if useLLM == false { return "stub mode" }
        switch LLMSettings.activeProvider() {
        case .none: return ""
        case .openAI: return "OpenAI"
        case .claude: return "Claude"
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

// Pure UI state for the breakdown generation pipeline. Owned by SongBreakdownStore so the
// task lifetime decouples from any one screen; the stepper / future surfaces simply read
// the current state for the note and render accordingly. Absence (no entry) = idle.
enum SongBreakdownGenerationState: Equatable {
    case running(startedAt: Date, providerLabel: String)
    case failed(message: String)
}
