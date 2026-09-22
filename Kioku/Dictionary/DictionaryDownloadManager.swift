// DictionaryDownloadManager.swift
//
// dictionary.sqlite (~350MB) is no longer bundled inside Kioku.app (see the Xcode target's
// Copy Bundle Resources phase) — it's downloaded once from a pinned GitHub Release asset into
// Application Support on first launch. Application Support, not Caches: a mid-download purge
// under storage pressure would strand the app with a half-written file and no dictionary — the
// same failure mode ModelStorage's header documents for the speech models
// (SwiftWhisperAlign/Sources/SwiftWhisperAlign/ModelStorage.swift).
//
// Progress comes from a delegate on a session this file owns. Do NOT reach for the shorter
// URLSession.shared.download(from:delegate:) — that delegate is task-scoped and never receives
// didWriteData, which silently reduces the banner to "0%" until the download finishes.
// WhisperModelManager (Kioku/Notes/WhisperModelManager.swift) still has that shape.

import Foundation
import Observation
import CryptoKit

// Errors produced while downloading or verifying the dictionary database.
enum DictionaryDownloadError: LocalizedError {
    case httpError(Int)
    case checksumMismatch
    case missingPayload

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server returned HTTP \(code)."
        case .checksumMismatch: return "Downloaded file did not match the expected checksum."
        case .missingPayload: return "The download finished but produced no file."
        }
    }
}

// Downloads and stores dictionary.sqlite in Application Support, with progress reporting for
// the first-launch gating UI (see DictionaryDownloadGateView).
@Observable
final class DictionaryDownloadManager {
    // Pinned to a specific release tag, not a moving tag — mirrors WhisperDownloadableModel's
    // pinnedRevision reasoning in WhisperModelManager.swift: a moving tag means a future edit to
    // the release silently changes the bytes every install receives. Bump both of these
    // deliberately (new tag + freshly computed hash) whenever dictionary.sqlite is rebuilt by
    // Resources/generate_db.py, THEN run scripts/publish_dictionary_release.sh by hand to
    // publish the matching GitHub Release — there is no CI automation for this step (no
    // publish-dictionary-release workflow exists; generate_db.py's upstream inputs are
    // gitignored, so only the machine that actually ran the generator has the right bytes).
    // Also: scripts/ensure_dictionary.sh runs on every local build and re-downloads from
    // whatever tag is pinned here if the local Resources/dictionary.sqlite doesn't hash-match
    // it — so editing dictionary.sqlite locally without bumping this pin first gets silently
    // reverted on the very next build.
    nonisolated static let releaseTag = "dictionary-v10"
    nonisolated static let expectedSHA256 = "d716c1654cd8ee3ccd78f74696ae173f7df5b971a50b5a45b10cd93f94c23355"

    // Public GitHub Release asset URL — matthewmorrone/Kioku is a public repo, so this needs no
    // authentication to fetch, same as the pinned huggingface.co URL WhisperModelManager uses.
    // nonisolated: DictionaryStore's init (Kioku/Dictionary/DictionaryStore.swift) reads this
    // from a nonisolated context reached via Task.detached in ContentView, which can't see a
    // MainActor-isolated member under this project's default MainActor isolation.
    nonisolated static var remoteURL: URL {
        URL(string: "https://github.com/matthewmorrone/Kioku/releases/download/\(releaseTag)/dictionary.sqlite")!
    }

    // Per-model subdirectory under Application Support where the downloaded database is stored.
    nonisolated static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Dictionary", isDirectory: true)
    }

    // The downloaded database's on-disk location, once installed.
    nonisolated static var installedDatabaseURL: URL {
        directory.appendingPathComponent("dictionary.sqlite")
    }

    // Records which releaseTag installedDatabaseURL's bytes actually came from. Without this,
    // isInstalled would treat ANY file at that path as current — so bumping releaseTag/
    // expectedSHA256 for a future dictionary.sqlite rebuild (see the comment above) would leave
    // existing installs silently stuck on old, checksum-mismatched-with-the-new-pin bytes
    // forever, since the app would never re-check them once installed once.
    nonisolated static var installedReleaseMarkerURL: URL {
        directory.appendingPathComponent("dictionary.sqlite.release")
    }

    // The release tag actually on disk right now, regardless of whether it matches the app's
    // current `releaseTag` pin — nil when nothing has ever been installed. Distinct from
    // `isInstalled` (which requires an exact match to the current pin): this is for surfacing
    // "what version do I actually have" in the About screen, including the stale-but-present
    // case where a device is mid-way through updating to a newer pinned release.
    nonisolated static var installedReleaseTag: String? {
        try? String(contentsOf: installedReleaseMarkerURL, encoding: .utf8)
    }

    // Static existence check for call sites without a DictionaryDownloadManager instance
    // (DictionaryStore's init has no observable-state owner to ask). Mirrors the instance
    // isInstalled's logic exactly; kept separate rather than having the instance property
    // delegate to this, because the instance property is meant to be the reactive source of
    // truth for SwiftUI and a static forwarding call would add an indirection with no benefit.
    // Requires the release marker to match the CURRENT releaseTag, not just file presence — see
    // installedReleaseMarkerURL.
    nonisolated static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: installedDatabaseURL.path) else { return false }
        let installedTag = try? String(contentsOf: installedReleaseMarkerURL, encoding: .utf8)
        return installedTag == releaseTag
    }

    // Reflects on-disk state; refreshed at init and after a successful download. An instance
    // property (not the static file-existence check directly) so SwiftUI can observe it.
    private(set) var isInstalled: Bool
    // 0...1 while a download is in flight; nil otherwise.
    private(set) var progress: Double?
    private(set) var errorMessage: String?

    // Snapshots the current on-disk install state.
    init() {
        isInstalled = Self.isInstalled
    }

    // Downloads dictionary.sqlite to Application Support, verifying its checksum before making
    // it visible at installedDatabaseURL. No-op if already installed or a download is in flight.
    // Explicitly @MainActor (redundant with this project's default MainActor isolation, but
    // documents that every direct property write below is safe to interleave with the delegate's
    // Task { @MainActor in ... } hop without a lock, since both land on the same serial executor).
    @MainActor
    func downloadIfNeeded() async {
        guard !isInstalled else { return }
        guard progress == nil else {
            AppLog.debug(.dictionaryDownload, "downloadIfNeeded: already in flight, skipping")
            return
        }

        progress = 0
        errorMessage = nil

        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            // Re-downloadable, ~350MB — keep it out of iCloud/device backups, mirroring
            // ModelStorage.directory(for:)'s identical reasoning for the speech models.
            var directoryURL = Self.directory
            var excludedFromBackup = URLResourceValues()
            excludedFromBackup.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(excludedFromBackup)

            AppLog.info(.dictionaryDownload, "downloadIfNeeded: starting from \(Self.remoteURL)")
            let tempURL = try await downloadToTemporaryFile()
            AppLog.debug(.dictionaryDownload, "downloadIfNeeded: temp file at \(tempURL.path)")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let digest = try Self.sha256(ofFileAt: tempURL)
            guard digest == Self.expectedSHA256 else {
                AppLog.error(.dictionaryDownload, "downloadIfNeeded: checksum mismatch — expected \(Self.expectedSHA256), got \(digest)")
                throw DictionaryDownloadError.checksumMismatch
            }

            if FileManager.default.fileExists(atPath: Self.installedDatabaseURL.path) {
                try FileManager.default.removeItem(at: Self.installedDatabaseURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: Self.installedDatabaseURL)
            try Self.releaseTag.write(to: Self.installedReleaseMarkerURL, atomically: true, encoding: .utf8)
            AppLog.info(.dictionaryDownload, "downloadIfNeeded: installed to \(Self.installedDatabaseURL.path)")

            progress = nil
            isInstalled = true
        } catch {
            AppLog.error(.dictionaryDownload, "downloadIfNeeded: failed — \(error.localizedDescription)")
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    // Runs the download and returns the file it landed in, reporting progress along the way.
    //
    // The delegate is attached to a session WE own, not handed to URLSession.shared's
    // download(from:delegate:) — a task-scoped delegate passed that way never receives
    // urlSession(_:downloadTask:didWriteData:...) at all, so `progress` stayed at the 0 set
    // above and the banner jumped straight from "0%" to gone. Measured against a 3.6MB asset:
    // 0 callbacks via the task delegate, 17 via a session delegate on the same URL.
    //
    // The session is invalidated on the way out: URLSession holds its delegate strongly until
    // invalidated, so skipping this leaks the delegate (and the manager it captures) per attempt.
    @MainActor
    private func downloadToTemporaryFile() async throws -> URL {
        let delegate = DictionaryDownloadProgressDelegate { [weak self] value in
            guard let self else { return }
            Task { @MainActor in self.progress = value }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.onFinish = { continuation.resume(with: $0) }
            session.downloadTask(with: Self.remoteURL).resume()
        }
    }

    // Streaming SHA-256 so a 350MB file isn't loaded into memory at once.
    nonisolated static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        while !chunk.isEmpty {
            hasher.update(data: chunk)
            chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// Session-level delegate for the dictionary download: relays progress to a closure and hands the
// finished file to `onFinish`. `downloadIfNeeded()` hops back to the isolated `self` via the
// `@MainActor` Task inside the progress closure, so this delegate itself only needs to be
// Sendable, not actor-isolated. Callbacks arrive on the session's own serial delegate queue, so
// the mutable state below is never touched concurrently.
private final class DictionaryDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    // Resumes downloadToTemporaryFile's continuation. Called exactly once — see didComplete.
    var onFinish: (@Sendable (Result<URL, Error>) -> Void)?

    // Where didFinishDownloadingTo moved the payload, read back once the task reports completion.
    private var downloadedURL: URL?
    private var finished = false

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    // Forwards download progress to the onProgress closure as a 0–1 fraction. A server that sends
    // no Content-Length reports -1 here, which would render as a nonsense percentage.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Takes ownership of the downloaded payload. URLSession deletes `location` as soon as this
    // returns, so the move has to happen here and synchronously rather than on a later hop.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-download-\(UUID().uuidString).sqlite")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedURL = destination
        } catch {
            AppLog.error(.dictionaryDownload, "didFinishDownloadingTo: could not keep payload — \(error.localizedDescription)")
        }
    }

    // The single completion point for the whole transfer: fires for success, network failure and
    // cancellation alike, and always after didFinishDownloadingTo. The HTTP status is checked here
    // rather than at the call site because that response is only reachable from the task.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished == false else { return }
        finished = true
        let result: Result<URL, Error>
        if let error {
            result = .failure(error)
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            if status != 200 {
                if let downloadedURL { try? FileManager.default.removeItem(at: downloadedURL) }
                result = .failure(DictionaryDownloadError.httpError(status))
            } else if let downloadedURL {
                result = .success(downloadedURL)
            } else {
                result = .failure(DictionaryDownloadError.missingPayload)
            }
        }
        onFinish?(result)
        onFinish = nil
    }
}
