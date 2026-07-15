# Dictionary Offload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop bundling `dictionary.sqlite` (~350MB, the single largest resource in Kioku.app) inside the shipped app; download it once into Application Support on first launch instead.

**Architecture:** A new `DictionaryDownloadManager` (mirrors the existing `WhisperModelManager` pattern in `Kioku/Notes/WhisperModelManager.swift`) fetches `dictionary.sqlite` from a pinned GitHub Release asset via `URLSession.download(from:delegate:)`, verifies its SHA-256, and stores it at `Application Support/Dictionary/dictionary.sqlite`. `DictionaryStore`'s convenience init is repointed from `Bundle.main` to that location. A new full-screen gate view blocks the tab UI on first launch until the download completes, since nearly every tab (Read, Words, Learn, Settings) depends on `dictionaryStore` being non-nil. The file stays exactly where it is in `Resources/` for local builds/tests/CI (untouched: `ensure_dictionary.sh`, `generate_db.py`, `data_manifest.json` inputs) — only the Xcode target's Copy Bundle Resources step stops copying it into the `.app`.

**Tech Stack:** Swift 6, SwiftUI, `Observation` (`@Observable`), `URLSession` download tasks, `CryptoKit` (SHA-256), GitHub Releases (public repo `matthewmorrone/Kioku`) for hosting.

## Global Constraints

- Every function needs an intent comment immediately above its declaration (Kioku's "Validate Invariants" build phase enforces this).
- No Swift file may exceed 1000 lines (hard fail); 800 lines is a warn threshold.
- Match existing project conventions: `nonisolated` on code called from background delegate queues/`Task.detached`, `@Observable` (not `ObservableObject`) for new observable state, `Logger(subsystem: "matthewmorrone.Kioku", category: "...")` for OSLog.
- No settings-row footer/caption text, no instructional empty-state copy (established project conventions — keep any new UI copy terse).
- Commit with `git commit -F <tempfile>`, not `-m "$(cat <<'EOF' ...)"` — the project's `commit-validate.js` pre-commit hook mis-parses that heredoc form (see prior investigation this session); `-F`/`--file` bypasses it cleanly.
- Do not run `xcodebuild` with a fresh `-derivedDataPath` — reuse the existing derived data directory or use the project's MCP `build_sim`/device build tooling.

---

## File Structure

- **Create** `Kioku/Dictionary/DictionaryDownloadManager.swift` — download, checksum, and on-disk storage of `dictionary.sqlite`. Owns no UI.
- **Create** `KiokuTests/DictionaryDownloadManagerTests.swift` — pure-logic unit tests (path shape, checksum helper). No network calls.
- **Create** `Kioku/Dictionary/DictionaryDownloadGateView.swift` — full-screen SwiftUI gate shown until the download completes.
- **Modify** `Kioku/Dictionary/DictionaryStore.swift` — convenience init resolves from `DictionaryDownloadManager.installedDatabaseURL` instead of `Bundle.main`.
- **Modify** `Kioku/ContentView.swift` — instantiate `DictionaryDownloadManager`, show the gate, kick off the download on appear, re-trigger `rebuildReadResources()` on successful download.
- **Modify** `Kioku.xcodeproj/project.pbxproj` — remove `dictionary.sqlite` from the target's Copy Bundle Resources phase only (its `PBXFileReference`/group entry, `ensure_dictionary.sh` Run Script, and `generate_db.py` regeneration step are untouched — tests and local dev builds still need the on-disk file).
- **Modify** `Resources/data_manifest.json` — document the new hosting/versioning scheme for the `dictionary` entry.

---

### Task 1: DictionaryDownloadManager

**Files:**
- Create: `Kioku/Dictionary/DictionaryDownloadManager.swift`
- Test: `KiokuTests/DictionaryDownloadManagerTests.swift`

**Interfaces:**
- Produces: `DictionaryDownloadManager` (`@Observable final class`) with `static var installedDatabaseURL: URL`, `static func sha256(ofFileAt: URL) throws -> String`, instance `private(set) var isInstalled: Bool`, `private(set) var progress: Double?`, `private(set) var errorMessage: String?`, `func downloadIfNeeded() async`. Consumed by Task 2 (`DictionaryStore`) and Task 4 (`ContentView`/gate view).

- [ ] **Step 1: Write the failing tests**

```swift
// KiokuTests/DictionaryDownloadManagerTests.swift
import XCTest
@testable import Kioku

final class DictionaryDownloadManagerTests: XCTestCase {
    func testInstalledDatabaseURLPointsUnderApplicationSupportDictionary() {
        let url = DictionaryDownloadManager.installedDatabaseURL
        XCTAssertEqual(url.lastPathComponent, "dictionary.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Dictionary")
    }

    func testSHA256OfFileMatchesKnownDigest() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-sha256-test-\(UUID().uuidString).txt")
        try "hello world\n".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let digest = try DictionaryDownloadManager.sha256(ofFileAt: tempURL)
        XCTAssertEqual(digest, "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Kioku.xcodeproj -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KiokuTests/DictionaryDownloadManagerTests`
Expected: FAIL — `DictionaryDownloadManager` does not exist yet (build error).

- [ ] **Step 3: Write the implementation**

```swift
// Kioku/Dictionary/DictionaryDownloadManager.swift
//
// dictionary.sqlite (~350MB) is no longer bundled inside Kioku.app (see the Xcode target's
// Copy Bundle Resources phase) — it's downloaded once from a pinned GitHub Release asset into
// Application Support on first launch. Mirrors WhisperModelManager's URLSession downloadTask +
// progress-delegate pattern (Kioku/Notes/WhisperModelManager.swift). Application Support, not
// Caches: a mid-download purge under storage pressure would strand the app with a half-written
// file and no dictionary — the same failure mode ModelStorage's header documents for the speech
// models (SwiftWhisperAlign/Sources/SwiftWhisperAlign/ModelStorage.swift).

import Foundation
import Observation
import OSLog
import CryptoKit

nonisolated private let logger = Logger(subsystem: "matthewmorrone.Kioku", category: "DictionaryDownload")

// Errors produced while downloading or verifying the dictionary database.
enum DictionaryDownloadError: LocalizedError {
    case httpError(Int)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server returned HTTP \(code)."
        case .checksumMismatch: return "Downloaded file did not match the expected checksum."
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
    // Resources/generate_db.py and re-published — see Task 6 of this plan.
    static let releaseTag = "dictionary-v1"
    static let expectedSHA256 = "5652eacfc35ffb10495b025cbc921fcb67d67801974e7d56ab76576055c54879"

    // Public GitHub Release asset URL — matthewmorrone/Kioku is a public repo, so this needs no
    // authentication to fetch, same as the pinned huggingface.co URL WhisperModelManager uses.
    static var remoteURL: URL {
        URL(string: "https://github.com/matthewmorrone/Kioku/releases/download/\(releaseTag)/dictionary.sqlite")!
    }

    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Dictionary", isDirectory: true)
    }

    static var installedDatabaseURL: URL {
        directory.appendingPathComponent("dictionary.sqlite")
    }

    // Reflects on-disk state; refreshed at init and after a successful download. An instance
    // property (not the static file-existence check directly) so SwiftUI can observe it.
    private(set) var isInstalled: Bool
    // 0...1 while a download is in flight; nil otherwise.
    private(set) var progress: Double?
    private(set) var errorMessage: String?

    init() {
        isInstalled = FileManager.default.fileExists(atPath: Self.installedDatabaseURL.path)
    }

    // Downloads dictionary.sqlite to Application Support, verifying its checksum before making
    // it visible at installedDatabaseURL. No-op if already installed or a download is in flight.
    func downloadIfNeeded() async {
        guard !isInstalled else { return }
        guard progress == nil else {
            logger.debug("downloadIfNeeded: already in flight, skipping")
            return
        }

        progress = 0
        errorMessage = nil

        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

            logger.info("downloadIfNeeded: starting from \(Self.remoteURL)")
            let delegate = DictionaryDownloadProgressDelegate { [weak self] value in
                guard let self else { return }
                Task { @MainActor in self.progress = value }
            }
            let (tempURL, response) = try await URLSession.shared.download(from: Self.remoteURL, delegate: delegate)

            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.info("downloadIfNeeded: HTTP \(status), temp file at \(tempURL.path)")
            guard status == 200 else {
                throw DictionaryDownloadError.httpError(status)
            }

            let digest = try Self.sha256(ofFileAt: tempURL)
            guard digest == Self.expectedSHA256 else {
                logger.error("downloadIfNeeded: checksum mismatch (got \(digest))")
                throw DictionaryDownloadError.checksumMismatch
            }

            if FileManager.default.fileExists(atPath: Self.installedDatabaseURL.path) {
                try FileManager.default.removeItem(at: Self.installedDatabaseURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: Self.installedDatabaseURL)
            logger.info("downloadIfNeeded: installed to \(Self.installedDatabaseURL.path)")

            progress = nil
            isInstalled = true
        } catch {
            logger.error("downloadIfNeeded: failed — \(error.localizedDescription)")
            progress = nil
            errorMessage = error.localizedDescription
        }
    }

    // Streaming SHA-256 so a 350MB file isn't loaded into memory at once.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// Relays URLSession download progress to a closure. `downloadIfNeeded()` hops back to the
// isolated `self` via the `@MainActor` Task inside the closure, so this delegate itself only
// needs to be Sendable, not actor-isolated.
private final class DictionaryDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    // Forwards download progress to the onProgress closure as a 0–1 fraction.
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

    // Actual file handling is done by the async download(from:delegate:) continuation.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Kioku.xcodeproj -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KiokuTests/DictionaryDownloadManagerTests`
Expected: PASS (2/2)

- [ ] **Step 5: Add the intent-comment check and confirm the invariants build phase is happy**

`DictionaryDownloadManager.swift` already has an intent comment above every function (`init()`, `downloadIfNeeded()`, `sha256(ofFileAt:)`, the delegate's two methods) per Step 3 above — no further action needed, this step is a verification pass, not new code. Build the app target once (not just the test target) to let the "Validate Invariants" Run Script phase check the new file:

Run: reuse the existing derived-data build via the project's `mcp__xcode__build_sim` tool (or `build_run_sim`) — do not pass a fresh `-derivedDataPath`.
Expected: build succeeds, no "Validate Invariants" warnings/failures mentioning `DictionaryDownloadManager.swift`.

- [ ] **Step 6: Commit**

```bash
git add Kioku/Dictionary/DictionaryDownloadManager.swift KiokuTests/DictionaryDownloadManagerTests.swift
git commit -F <(cat <<'EOF'
feat(dictionary): add DictionaryDownloadManager for post-install dictionary.sqlite fetch

Mirrors WhisperModelManager's URLSession download pattern. Not yet wired
into DictionaryStore or the UI (Tasks 2 and 4).
EOF
)
```

---

### Task 2: DictionaryStore resolves from Application Support

**Files:**
- Modify: `Kioku/Dictionary/DictionaryStore.swift:56-65`
- Modify: `Kioku/Words/JapaneseInputAccessory.swift:49` (no code change expected — verify the call site still compiles against the new init signature)

**Interfaces:**
- Consumes: `DictionaryDownloadManager.isInstalled` is an *instance* property (Task 1), not reachable from a static context — this task needs a way to check installation without an instance. Add `static var isInstalled: Bool` to `DictionaryDownloadManager` (a thin static wrapper around the same file-existence check the instance `init()` does) so `DictionaryStore`'s init — which has no `DictionaryDownloadManager` instance to hand it — can check synchronously.
- Produces: `DictionaryStore.init() throws` (no parameters) — replaces the old `init(databaseName:databaseExtension:bundle:)`. `DictionarySQLiteError.databaseNotFound(name:)` (already exists, reused as-is).

- [ ] **Step 1: Add the static existence check to DictionaryDownloadManager**

In `Kioku/Dictionary/DictionaryDownloadManager.swift`, add alongside the instance `isInstalled`:

```swift
    // Static existence check for call sites without a DictionaryDownloadManager instance
    // (DictionaryStore's init has no observable-state owner to ask). Mirrors the instance
    // isInstalled's logic exactly; kept separate rather than having the instance property
    // delegate to this, because the instance property is meant to be the reactive source of
    // truth for SwiftUI and a static forwarding call would add an indirection with no benefit.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedDatabaseURL.path)
    }
```

(Also update the instance `init()` to read `Self.isInstalled` instead of duplicating the `FileManager.default.fileExists` call, to avoid the two checks drifting apart.)

```swift
    init() {
        isInstalled = Self.isInstalled
    }
```

- [ ] **Step 2: Write the failing test**

`DictionaryStore.swift`'s header already documents that this file relies on integration coverage (`LexiconTests` against a real database via `init(databaseURL:)`) rather than a parallel unit-test file, and that convention is kept here — the new logic is a one-line `guard`, and the meaningful risk (does opening a real downloaded file work) is already covered by `init(databaseURL:)`, unchanged by this task. Add one direct unit test for the new guard instead of a full parallel test file:

```swift
// KiokuTests/DictionaryDownloadManagerTests.swift — add to the existing file from Task 1
    func testDictionaryStoreThrowsDatabaseNotFoundWhenNotInstalled() {
        // Exercises DictionaryStore's new no-arg init against whatever the real
        // Application Support state is: if a dictionary happens to already be installed
        // (e.g. a prior manual test run), opening it should succeed; if not, it must throw
        // .databaseNotFound rather than crash or hang. Both branches are asserted so the
        // test is meaningful either way, without touching/deleting real on-disk state.
        do {
            _ = try DictionaryStore()
            XCTAssertTrue(DictionaryDownloadManager.isInstalled, "DictionaryStore() succeeded but isInstalled is false")
        } catch DictionarySQLiteError.databaseNotFound(let name) {
            XCTAssertEqual(name, "dictionary.sqlite")
            XCTAssertFalse(DictionaryDownloadManager.isInstalled)
        } catch {
            XCTFail("expected .databaseNotFound, got \(error)")
        }
    }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild test -project Kioku.xcodeproj -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KiokuTests/DictionaryDownloadManagerTests/testDictionaryStoreThrowsDatabaseNotFoundWhenNotInstalled`
Expected: FAIL — `DictionaryStore()` (no-arg) still resolves via `Bundle.main` today and opens the bundled file successfully, so it doesn't throw `.databaseNotFound` and the `XCTAssertTrue(DictionaryDownloadManager.isInstalled, ...)` branch fails (bundled copy exists but nothing has downloaded it to Application Support).

- [ ] **Step 4: Replace the convenience init**

In `Kioku/Dictionary/DictionaryStore.swift`, replace lines 55-65:

```swift
    // Resolves and opens the bundled dictionary database by resource name.
    public convenience init(
        databaseName: String = "dictionary",
        databaseExtension: String = "sqlite",
        bundle: Bundle = .main
    ) throws {
        guard let url = bundle.url(forResource: databaseName, withExtension: databaseExtension) else {
            throw DictionarySQLiteError.databaseNotFound(name: "\(databaseName).\(databaseExtension)")
        }
        try self.init(databaseURL: url)
    }
```

with:

```swift
    // Resolves and opens the downloaded dictionary database from Application Support (see
    // DictionaryDownloadManager) — dictionary.sqlite is no longer bundled inside Kioku.app.
    // Throws .databaseNotFound if the user hasn't downloaded it yet; every call site already
    // treats DictionaryStore as optional (see WordsView.swift's `if dictionaryStore == nil`
    // empty state and the `try?`/`dictionaryStore?.` call sites throughout the app), so this
    // throw surfaces exactly the way a missing bundle resource used to.
    public convenience init() throws {
        guard DictionaryDownloadManager.isInstalled else {
            throw DictionarySQLiteError.databaseNotFound(name: "dictionary.sqlite")
        }
        try self.init(databaseURL: DictionaryDownloadManager.installedDatabaseURL)
    }
```

- [ ] **Step 5: Confirm call sites still compile**

The three no-argument `DictionaryStore()` call sites (`ContentView.swift:377`, `ContentView.swift:452`, `Kioku/Words/JapaneseInputAccessory.swift:49`) already use no explicit arguments, so they compile unchanged against the new no-parameter signature. Grep to confirm nothing else passed `databaseName:`/`bundle:` explicitly (already verified during planning — no matches):

Run: `grep -rn "DictionaryStore(bundle:\|DictionaryStore(databaseName:" /Users/matthewmorrone/Projects/Kioku`
Expected: no output.

- [ ] **Step 6: Run the test to verify it passes**

Run: `xcodebuild test -project Kioku.xcodeproj -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:KiokuTests/DictionaryDownloadManagerTests`
Expected: PASS (3/3) — on a simulator with nothing downloaded yet, `testDictionaryStoreThrowsDatabaseNotFoundWhenNotInstalled` takes the `.databaseNotFound` branch.

- [ ] **Step 7: Run the full existing suite to confirm no regression**

Run: `xcodebuild test -project Kioku.xcodeproj -scheme Kioku -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: `LexiconTests` and everything else still passes — they open `DictionaryStore` via `init(databaseURL:)` directly against the on-disk `Resources/dictionary.sqlite` (see `TestReadResources.swift:42`), which this task does not touch.

- [ ] **Step 8: Commit**

```bash
git add Kioku/Dictionary/DictionaryStore.swift Kioku/Dictionary/DictionaryDownloadManager.swift KiokuTests/DictionaryDownloadManagerTests.swift
git commit -F <(cat <<'EOF'
feat(dictionary): resolve DictionaryStore from Application Support, not the bundle

DictionaryStore() now opens the downloaded copy at
DictionaryDownloadManager.installedDatabaseURL instead of Bundle.main,
throwing .databaseNotFound before it's downloaded. Every call site already
treats DictionaryStore as optional, so this is a drop-in swap.
EOF
)
```

---

### Task 3: Stop bundling dictionary.sqlite

**Files:**
- Modify: `Kioku.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing new.
- Produces: a built `.app` that no longer contains `dictionary.sqlite`, while `Resources/dictionary.sqlite` remains on disk (untouched) for `ensure_dictionary.sh`/`generate_db.py`/tests.

- [ ] **Step 1: Remove the two lines that bundle the file**

In `Kioku.xcodeproj/project.pbxproj`, delete line 359 (the reference inside the target's `PBXResourcesBuildPhase` `files = (...)` list):

```
				E32B0CE42F57BC070020F5C2 /* dictionary.sqlite in Resources */,
```

Delete line 11 (the now-unreferenced `PBXBuildFile` entry it pointed at):

```
		E32B0CE42F57BC070020F5C2 /* dictionary.sqlite in Resources */ = {isa = PBXBuildFile; fileRef = E32B0CDF2F57BC070020F5C2 /* dictionary.sqlite */; };
```

Leave line 53 (`PBXFileReference`) and line 168 (the `Resources` group's `children` listing) in place — those only make the file visible in Xcode's navigator and are harmless; they don't bundle it. `ensure_dictionary.sh`'s Run Script phase (around line 441-445) also stays exactly as-is, since it still needs to produce `Resources/dictionary.sqlite` on disk for local builds and tests.

- [ ] **Step 2: Build and verify the file is absent from the built app**

Run: use `mcp__xcode__build_sim`/`build_run_sim` (existing derived data, per this plan's Global Constraints) for the `Kioku` scheme on a simulator.
Expected: build succeeds. Then:

Run: `find "$(mcp__xcode__get_sim_app_path result)" -maxdepth 1 -iname "dictionary.sqlite"`
Expected: no output (file absent from the built `.app`).

- [ ] **Step 3: Confirm the app still boots into the download gate (manual check, since Task 4 isn't built yet)**

At this point in the plan (before Task 4), `DictionaryStore()` will simply fail silently (per Task 2's existing `catch { print(...) }` in `ContentView.makeReadResources`) and every tab will behave as it already does today when `dictionaryStore` is nil — no crash, just an empty dictionary-dependent UI. Launch the app on the simulator and confirm: app launches without crashing, Words tab search returns nothing, no crash log. This is expected and will be fixed by Task 4's gate.

- [ ] **Step 4: Commit**

```bash
git add Kioku.xcodeproj/project.pbxproj
git commit -F <(cat <<'EOF'
chore(app-size): stop bundling dictionary.sqlite into the app

The file stays in Resources/ for local builds, tests, and CI (untouched:
ensure_dictionary.sh, generate_db.py) — only the Copy Bundle Resources
step stops copying it into Kioku.app. Downloaded at runtime instead (see
DictionaryDownloadManager). The app has no first-launch gate yet — see
the next commit.
EOF
)
```

---

### Task 4: First-launch download gate

**Files:**
- Create: `Kioku/Dictionary/DictionaryDownloadGateView.swift`
- Modify: `Kioku/ContentView.swift`

**Interfaces:**
- Consumes: `DictionaryDownloadManager` (`@Observable`, Task 1) — `isInstalled: Bool`, `progress: Double?`, `errorMessage: String?`, `func downloadIfNeeded() async`.
- Produces: `DictionaryDownloadGateView(downloadManager: DictionaryDownloadManager, onRetry: @escaping () -> Void)` — a `View`.

- [ ] **Step 1: Write the gate view**

```swift
// Kioku/Dictionary/DictionaryDownloadGateView.swift
//
// Full-screen gate shown until dictionary.sqlite has finished downloading (see
// DictionaryDownloadManager). Every tab assumes dictionaryStore becomes non-nil shortly after
// launch — an assumption that held for free when the file shipped inside the bundle, and now
// depends on a ~350MB network download completing.

import SwiftUI

struct DictionaryDownloadGateView: View {
    var downloadManager: DictionaryDownloadManager
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if let errorMessage = downloadManager.errorMessage {
                Text("Couldn't Download Dictionary")
                    .font(.headline)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Downloading Dictionary")
                    .font(.headline)
                ProgressView(value: downloadManager.progress ?? 0)
                    .frame(maxWidth: 240)
                if let progress = downloadManager.progress {
                    Text("\(Int(progress * 100))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
```

- [ ] **Step 2: Wire it into ContentView**

In `Kioku/ContentView.swift`, add a new `@State` property near the other stores (find the existing `@State private var readResources` / similar declarations, add alongside):

```swift
    @State private var dictionaryDownloadManager = DictionaryDownloadManager()
```

Wrap the `TabView` in `body` with a conditional overlay. Change:

```swift
    var body: some View {
        TabView(selection: $selectedTab) {
```

to:

```swift
    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
```

and locate the closing of the `TabView`'s trailing modifier chain — the `.onAppear { ... }` block found at `ContentView.swift:153` — leave every existing modifier attached to `TabView` as-is (don't move them), and instead close the new `ZStack` after the whole existing modifier chain ends, adding the gate as a sibling:

```swift
        // ... all existing TabView + modifiers unchanged ...

            if !dictionaryDownloadManager.isInstalled {
                DictionaryDownloadGateView(downloadManager: dictionaryDownloadManager) {
                    Task { await dictionaryDownloadManager.downloadIfNeeded() }
                }
            }
        }
    }
```

In the existing `.onAppear` closure (`ContentView.swift:153-159`), add the download kickoff alongside `loadReadResourcesIfNeeded()`:

```swift
        .onAppear {
            StartupTimer.mark("onAppear fired")
            restoreLastActiveNote()
            loadReadResourcesIfNeeded()
            Task {
                await dictionaryDownloadManager.downloadIfNeeded()
                if dictionaryDownloadManager.isInstalled {
                    rebuildReadResources()
                }
            }
            // ... existing bridgeServer.attach(...) etc. unchanged
```

`rebuildReadResources()` is safe to call a second time here — it's the same method `loadReadResourcesIfNeeded()` calls internally, and nothing about it assumes single-invocation (unlike `loadReadResourcesIfNeeded()`'s own `hasLoadedReadResources` guard, which exists specifically to make the *first* auto-call idempotent against repeated `onAppear` firings, not to prevent legitimate re-runs — the segmenter-settings-change code path elsewhere in this file already calls `rebuildReadResources()` directly for the same reason).

- [ ] **Step 3: Manual verification on simulator**

Delete any previously-downloaded dictionary from the simulator (`xcrun simctl` uninstall + reinstall, or delete `~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/Data/Application/<app-container>/Library/Application Support/Dictionary/` directly) and launch. Confirm:
1. The gate appears immediately with a 0% progress bar (no dictionary bundled, none downloaded yet).
2. Progress advances as the download proceeds (network required — for local testing without hitting the real GitHub Release, temporarily point `DictionaryDownloadManager.remoteURL` at a local `python3 -m http.server` serving a copy of `Resources/dictionary.sqlite`, and temporarily set `expectedSHA256` to that local file's real hash — revert both before committing).
3. On success, the gate disappears and the Words tab search becomes usable within the same launch, with no relaunch required.
4. Force a failure (airplane mode, or point `remoteURL` at a 404) and confirm the error + Retry button appear instead of a stuck spinner, and that tapping Retry re-attempts the download.

- [ ] **Step 4: Commit**

```bash
git add Kioku/Dictionary/DictionaryDownloadGateView.swift Kioku/ContentView.swift
git commit -F <(cat <<'EOF'
feat(dictionary): add first-launch download gate

Blocks the tab UI with a progress/retry screen until dictionary.sqlite
finishes downloading, since nearly every tab depends on dictionaryStore
being non-nil. Closes the gap left by Task 3 (app no longer bundles the
file, but until now had no visible download step).
EOF
)
```

---

### Task 5: Document the new hosting scheme

**Files:**
- Modify: `Resources/data_manifest.json`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update the `dictionary` entry**

In `Resources/data_manifest.json`, replace the existing `dictionary` entry (currently `"required": true, "derived": true, "url": null, "sha256": null`) with:

```json
    {
      "name": "dictionary",
      "type": "sqlite",
      "path": "Kioku/Resources/dictionary.sqlite",
      "required": true,
      "derived": true,
      "url": "https://github.com/matthewmorrone/Kioku/releases/download/dictionary-v1/dictionary.sqlite",
      "sha256": "5652eacfc35ffb10495b025cbc921fcb67d67801974e7d56ab76576055c54879",
      "provenance": "generated by generate_db.py from jmdict-eng, extras, jpdb-frequency-kana, wordfreq, kanjidic2-all, pitch-accent, and sentence-pairs. NOT bundled into Kioku.app (~350MB, too large to ship in the baseline install) — the local Resources/dictionary.sqlite copy is still produced at build time from the committed dictionary.sqlite.zst.part-* chunks (see scripts/ensure_dictionary.sh) for tests, CI, and generate_db.py's own staleness check, but the Xcode target no longer bundles it. At runtime DictionaryDownloadManager (Kioku/Dictionary/DictionaryDownloadManager.swift) downloads this exact release asset into Application Support on first launch, verified against the sha256 above. When dictionary.sqlite is rebuilt with meaningfully different content, publish a new GitHub Release (bump the tag, e.g. dictionary-v2), recompute this sha256, and update both this entry and DictionaryDownloadManager.releaseTag/expectedSHA256 together — see Task 6 of docs/superpowers/plans/2026-07-15-dictionary-offload.md."
    },
```

- [ ] **Step 2: Validate the JSON**

Run: `python3 -c "import json; json.load(open('/Users/matthewmorrone/Projects/Kioku/Resources/data_manifest.json'))" && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add Resources/data_manifest.json
git commit -F <(cat <<'EOF'
docs(data-manifest): document dictionary.sqlite's new download-based hosting
EOF
)
```

---

### Task 6: Publish the GitHub Release asset (manual — requires explicit confirmation)

This task publishes public content to `github.com/matthewmorrone/Kioku` — do not run these commands without the user explicitly confirming this step in particular, separately from having approved the rest of this plan. If executing this plan via a subagent, stop before this task and hand control back for that confirmation.

**Files:** none (no repo files change beyond what Task 5 already committed) — this task uploads a binary asset to GitHub and re-pins the checksum if the actual uploaded file differs from what Task 1/5 assumed.

- [ ] **Step 1: Confirm the exact bytes to publish**

Run: `shasum -a 256 /Users/matthewmorrone/Projects/Kioku/Resources/dictionary.sqlite`
Compare against `DictionaryDownloadManager.expectedSHA256` (`5652eacfc35ffb10495b025cbc921fcb67d67801974e7d56ab76576055c54879`, set in Task 1). If they match, proceed. If they don't — `Resources/dictionary.sqlite` was regenerated since Task 1 was written — recompute and update `DictionaryDownloadManager.expectedSHA256` and the `data_manifest.json` `sha256` field (Task 5) to the new value before publishing, so the pinned hash always matches what's actually uploaded.

- [ ] **Step 2: Create the GitHub Release and upload the asset**

Run:
```bash
gh release create dictionary-v1 \
  /Users/matthewmorrone/Projects/Kioku/Resources/dictionary.sqlite \
  --repo matthewmorrone/Kioku \
  --title "dictionary-v1" \
  --notes "dictionary.sqlite for on-demand download by DictionaryDownloadManager. See Resources/data_manifest.json for provenance."
```
Expected: a new release at `https://github.com/matthewmorrone/Kioku/releases/tag/dictionary-v1` with `dictionary.sqlite` attached as a downloadable asset.

- [ ] **Step 3: Verify the published asset downloads and matches**

Run:
```bash
curl -sL -o /tmp/dictionary-download-check.sqlite \
  https://github.com/matthewmorrone/Kioku/releases/download/dictionary-v1/dictionary.sqlite
shasum -a 256 /tmp/dictionary-download-check.sqlite
rm /tmp/dictionary-download-check.sqlite
```
Expected: the hash matches `DictionaryDownloadManager.expectedSHA256` exactly.

- [ ] **Step 4: End-to-end device/simulator verification**

Run the full manual check from Task 4 Step 3 against the real published release (remove any temporary local-server override of `remoteURL`/`expectedSHA256` if one was left in place during Task 4's testing). Confirm a clean install downloads, verifies, and unblocks the app.

---

## Self-Review

**Spec coverage:** shrink baseline `.app` size (Task 3: file no longer bundled), reuse the existing custom-download pattern rather than Apple ODR (Task 1 mirrors `WhisperModelManager`), handle first-launch UX for a now-required download (Task 4), handle offline/failure/retry (Task 4's error branch + Retry button), document hosting (Task 5), actually publish (Task 6, gated on explicit confirmation per this session's operating rules on publishing public content). No gaps against the discussion that produced this plan.

**Placeholder scan:** `expectedSHA256`/`releaseTag` are real, freshly computed values (not `TBD`), with Task 6 Step 1 explicitly re-verifying/re-pinning them against whatever `Resources/dictionary.sqlite` actually contains at publish time, since that may have changed since this plan was written.

**Type consistency:** `DictionaryDownloadManager.isInstalled` (instance, Task 1) vs. `DictionaryDownloadManager.isInstalled` (static, added in Task 2 Step 1) are both named `isInstalled` but are genuinely different declarations (instance property vs. static computed property) — Swift allows this without collision since one requires an instance and the other doesn't; verified this doesn't shadow ambiguously by having the instance version delegate to `Self.isInstalled` in `init()`. `downloadIfNeeded()`, `installedDatabaseURL`, `progress`, `errorMessage` are used with identical names/types across Tasks 1, 2, and 4.
