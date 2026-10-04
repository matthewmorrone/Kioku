// DictionaryDownloadManager.swift
//
// dictionary.sqlite (~384MB) is not bundled inside Kioku.app — it's downloaded once, xz-compressed
// (~100MB, see DictionaryArchiveExtractor), from a pinned GitHub Release asset and unpacked into
// Application Support on first launch. Application Support, not Caches: a
// mid-download purge under storage pressure would strand the app with a half-written file and no
// dictionary — the same failure mode ModelStorage's header documents for the speech models
// (LyricAlignment/Sources/LyricAlignment/ModelStorage.swift).
//
// Progress comes from a delegate on a session this file owns. Do NOT reach for the shorter
// URLSession.shared.download(from:delegate:) — that delegate is task-scoped and never receives
// didWriteData, which silently reduces the banner to "0%" until the download finishes.

import Compression
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
// the first-launch status banner (see DictionaryDownloadBanner).
@Observable
final class DictionaryDownloadManager {
    // Pinned to a specific release tag, not a moving tag: a moving tag means a future edit to the
    // release silently changes the bytes every install receives. Bump both of these
    // deliberately (new tag + freshly computed hash) whenever dictionary.sqlite is rebuilt by
    // Resources/generate_db.py, THEN run scripts/publish_dictionary_release.sh by hand to
    // publish the matching GitHub Release — there is no CI automation for this step (no
    // publish-dictionary-release workflow exists; generate_db.py's upstream inputs are
    // gitignored, so only the machine that actually ran the generator has the right bytes).
    // Also: scripts/ensure_dictionary.sh runs on every local build and re-downloads from
    // whatever tag is pinned here if the local Resources/dictionary.sqlite doesn't hash-match
    // it — so editing dictionary.sqlite locally without bumping this pin first gets silently
    // reverted on the very next build.
    nonisolated static let releaseTag = "dictionary-v15"
    nonisolated static let expectedSHA256 = "a4c138b3556c4781f1e510c67d307dd5434ec3aeee1a8b2e0515fbb2df9c2866"

    // Debug builds follow this moving release instead of the pin, so a dictionary rebuilt on the
    // Mac reaches the developer's phone without a new pinned version: scripts/
    // publish_dictionary_release.sh --dev overwrites its assets, including dictionary.sqlite.sha256,
    // which the app compares against what it has (checkForDevUpdate). Release builds never read it.
    nonisolated static let devChannelTag = "dictionary-dev"

    // The release this build downloads from.
    nonisolated static var channelTag: String {
        #if DEBUG
        devChannelTag
        #else
        releaseTag
        #endif
    }

    // Public GitHub Release asset URL of the xz-compressed database — matthewmorrone/Kioku is a
    // public repo, so this needs no authentication to fetch. The release also carries the raw
    // dictionary.sqlite, which scripts/ensure_dictionary.sh and CI download; the app takes the
    // archive because it is a quarter of the size. `expectedSHA256` pins the UNCOMPRESSED bytes.
    nonisolated static var remoteURL: URL {
        URL(string: "https://github.com/matthewmorrone/Kioku/releases/download/\(channelTag)/dictionary.sqlite.xz")!
    }

    // The dev release's checksum of its uncompressed dictionary.sqlite (a one-line text asset).
    nonisolated static var devChecksumURL: URL {
        URL(string: "https://github.com/matthewmorrone/Kioku/releases/download/\(devChannelTag)/dictionary.sqlite.sha256")!
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
        installedMarker?.split(separator: " ").first.map(String.init)
    }

    // The checksum recorded with a dev-channel install ("dictionary-dev <sha256>"), nil otherwise.
    nonisolated static var installedDevSHA256: String? {
        let parts = installedMarker?.split(separator: " ") ?? []
        return parts.count == 2 && parts[0] == devChannelTag ? String(parts[1]) : nil
    }

    // The marker file's contents: the release tag, plus the checksum for a dev-channel install.
    nonisolated private static var installedMarker: String? {
        try? String(contentsOf: installedReleaseMarkerURL, encoding: .utf8)
    }

    // Static existence check for call sites without a DictionaryDownloadManager instance
    // (DictionaryStore's init has no observable-state owner to ask). Mirrors the instance
    // isInstalled's logic exactly; kept separate rather than having the instance property
    // delegate to this, because the instance property is meant to be the reactive source of
    // truth for SwiftUI and a static forwarding call would add an indirection with no benefit.
    // Requires the release marker to match the CURRENT releaseTag, not just file presence — see
    // installedReleaseMarkerURL.
    //
    // A debug build counts any downloaded dictionary as installed: it keeps working on whatever it
    // has (even the pinned release) while offline, and checkForDevUpdate decides when to replace it.
    nonisolated static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: installedDatabaseURL.path) else { return false }
        #if DEBUG
        return installedReleaseTag != nil
        #else
        return installedReleaseTag == releaseTag
        #endif
    }

    // Reflects on-disk state; refreshed at init and after a successful download. An instance
    // property (not the static file-existence check directly) so SwiftUI can observe it.
    private(set) var isInstalled: Bool
    // 0...1 while a download is in flight; nil otherwise.
    private(set) var progress: Double?
    // True while the downloaded archive is being unpacked and verified (a few seconds).
    private(set) var isUnpacking = false
    private(set) var errorMessage: String?
    // A debug build's dev release has a different dictionary than the one installed.
    private(set) var updateAvailable = false
    // The dev release's checksum, read by checkForDevUpdate and verified after unpacking.
    private var devExpectedSHA256: String?

    // Snapshots the current on-disk install state.
    init() {
        isInstalled = Self.isInstalled
    }

    // Downloads the dictionary archive, unpacks it next to installedDatabaseURL and verifies the
    // unpacked bytes against the pin before making it visible at installedDatabaseURL. No-op if already installed or a download is in flight.
    // Explicitly @MainActor (redundant with this project's default MainActor isolation, but
    // documents that every direct property write below is safe to interleave with the delegate's
    // Task { @MainActor in ... } hop without a lock, since both land on the same serial executor).
    // Returns true when a new dictionary was installed.
    @MainActor
    @discardableResult
    func downloadIfNeeded() async -> Bool {
        guard !isInstalled || updateAvailable else { return false }
        guard progress == nil else {
            AppLog.debug(.dictionaryDownload, "downloadIfNeeded: already in flight, skipping")
            return false
        }

        progress = 0
        errorMessage = nil

        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            // Re-downloadable, ~384MB — keep it out of iCloud/device backups, mirroring
            // ModelStorage.directory(for:)'s identical reasoning for the speech models.
            var directoryURL = Self.directory
            var excludedFromBackup = URLResourceValues()
            excludedFromBackup.isExcludedFromBackup = true
            try? directoryURL.setResourceValues(excludedFromBackup)

            #if DEBUG
            if devExpectedSHA256 == nil { await checkForDevUpdate() }
            guard let expectedSHA256 = devExpectedSHA256 else { throw DictionaryDownloadError.missingPayload }
            let marker = "\(Self.devChannelTag) \(expectedSHA256)"
            #else
            let expectedSHA256 = Self.expectedSHA256
            let marker = Self.releaseTag
            #endif
            AppLog.info(.dictionaryDownload, "downloadIfNeeded: starting from \(Self.remoteURL)")
            StartupTimer.mark("dictionary download started (\(Self.channelTag))")
            let tempURL = try await downloadToTemporaryFile()
            StartupTimer.mark("dictionary download finished")
            AppLog.debug(.dictionaryDownload, "downloadIfNeeded: temp file at \(tempURL.path)")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            // Unpack beside the final location (same volume, so the move below is a rename) and off
            // the main actor: decoding ~384MB takes several seconds on a phone.
            isUnpacking = true
            defer { isUnpacking = false }
            let stagingURL = Self.directory.appendingPathComponent("dictionary.sqlite.unpacking")
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            let digest = try await Task.detached(priority: .userInitiated) {
                try StartupTimer.measure("dictionary unpack + checksum") {
                    try DictionaryArchiveExtractor.extract(archiveAt: tempURL, to: stagingURL)
                }
            }.value
            guard digest == expectedSHA256 else {
                AppLog.error(.dictionaryDownload, "downloadIfNeeded: checksum mismatch — expected \(expectedSHA256), got \(digest)")
                throw DictionaryDownloadError.checksumMismatch
            }

            if FileManager.default.fileExists(atPath: Self.installedDatabaseURL.path) {
                try FileManager.default.removeItem(at: Self.installedDatabaseURL)
            }
            try FileManager.default.moveItem(at: stagingURL, to: Self.installedDatabaseURL)
            try marker.write(to: Self.installedReleaseMarkerURL, atomically: true, encoding: .utf8)
            AppLog.info(.dictionaryDownload, "downloadIfNeeded: installed to \(Self.installedDatabaseURL.path)")

            StartupTimer.mark("dictionary installed")
            progress = nil
            isInstalled = true
            updateAvailable = false
            return true
        } catch {
            AppLog.error(.dictionaryDownload, "downloadIfNeeded: failed — \(error.localizedDescription)")
            progress = nil
            // A corrupt or truncated archive surfaces from the decoder as a bare FilterError,
            // whose system description means nothing to a reader.
            errorMessage = error is FilterError
                ? "The downloaded dictionary was damaged. Tap Retry to download it again."
                : error.localizedDescription
            return false
        }
    }

    // Debug builds: reads the dev release's checksum and flags an update when it differs from the
    // installed dictionary's. A failed check (offline, no dev release yet) changes nothing.
    @MainActor
    func checkForDevUpdate() async {
        var request = URLRequest(url: Self.devChecksumURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                AppLog.info(.dictionaryDownload, "checkForDevUpdate: no dev release checksum (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))")
                return
            }
            let remote = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard remote.count == 64 else { return }
            devExpectedSHA256 = remote
            updateAvailable = remote != Self.installedDevSHA256
        } catch {
            AppLog.info(.dictionaryDownload, "checkForDevUpdate: \(error.localizedDescription)")
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
            .appendingPathComponent("dictionary-download-\(UUID().uuidString).sqlite.xz")
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
