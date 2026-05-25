import XCTest
@testable import Kioku

// Characterizes NotesAudioStore's file-backed persistence for audio attachments and their
// SRT/cue/timing sidecars. Production reaches the store via the .shared singleton rooted at
// Documents/audio; these tests construct instances against a per-case temp directory so they
// never touch real user data. Pattern mirrors NotesStoreTests (per-case temp root in setUp /
// tearDown, no UserDefaults state involved).
@MainActor
final class NotesAudioStoreTests: XCTestCase {

    private var testRoot: URL!
    private var store: NotesAudioStore!

    override func setUp() async throws {
        try await super.setUp()
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-audio-tests-\(UUID().uuidString)", isDirectory: true)
        store = NotesAudioStore(audioDirectory: testRoot)
    }

    override func tearDown() async throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        store = nil
        try await super.tearDown()
    }

    // saveCues -> loadCues round-trips identical contents. Pins the JSON sidecar format so a
    // schema change is forced to update this test before silently breaking on-disk compatibility.
    func testSaveCuesRoundTrips() throws {
        let id = UUID()
        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "猫"),
            SubtitleCue(index: 2, startMs: 1000, endMs: 2500, text: "犬と鳥"),
        ]
        try store.saveCues(cues, attachmentID: id)
        XCTAssertEqual(store.loadCues(for: id), cues)
    }

    // loadCues returns an empty array when the sidecar is missing — readers depend on
    // "no cues yet" being a normal empty case, not a thrown error, because the renderer
    // tolerates empty cues but not exceptions on the playback path.
    func testLoadCuesMissingFileReturnsEmpty() {
        XCTAssertTrue(store.loadCues(for: UUID()).isEmpty)
    }

    // saveCueTimings -> loadCueTimings round-trips the nested dictionary contents. CueCharTimings
    // is a typealias for [Int: [CueCharTiming]] so encoder/decoder behavior on integer-keyed
    // dictionaries is on the hook here; JSONEncoder serializes those as string keys.
    func testSaveCueTimingsRoundTrips() throws {
        let id = UUID()
        let timings: CueCharTimings = [
            1: [
                CueCharTiming(timeMs: 0, charOffsetInCue: 0, charLength: 1),
                CueCharTiming(timeMs: 250, charOffsetInCue: 1, charLength: 2),
            ],
            2: [CueCharTiming(timeMs: 1100, charOffsetInCue: 0, charLength: 3)],
        ]
        try store.saveCueTimings(timings, attachmentID: id)
        XCTAssertEqual(store.loadCueTimings(for: id), timings)
    }

    // saveCueTimings([:]) is the canonical "remove karaoke data" path: the production comment
    // calls this out explicitly because callers must not have to know whether a stale file
    // remains from a previous run. Without this contract, importAttachment of an older backup
    // would silently leave prior checkpoints driving the per-word band.
    func testSaveCueTimingsEmptyRemovesFile() throws {
        let id = UUID()
        try store.saveCueTimings(
            [1: [CueCharTiming(timeMs: 100, charOffsetInCue: 0, charLength: 1)]],
            attachmentID: id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cueTimingsURL(for: id).path))

        try store.saveCueTimings([:], attachmentID: id)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.cueTimingsURL(for: id).path),
            "Empty timings must remove the stale file; otherwise loadCueTimings keeps returning prior data"
        )
    }

    // loadCueTimings returns an empty dictionary when the sidecar is missing — same
    // "missing = empty, never error" contract as loadCues.
    func testLoadCueTimingsMissingFileReturnsEmpty() {
        XCTAssertTrue(store.loadCueTimings(for: UUID()).isEmpty)
    }

    // saveSRT -> loadSRT round-trips UTF-8 text — the common path when our own SRT writers
    // (BulkImportRunner, SubtitleEditorSheet) save what they generate.
    func testSaveSRTRoundTripsUtf8() throws {
        let id = UUID()
        let srt = "1\n00:00:00,000 --> 00:00:01,000\n猫\n"
        _ = try store.saveSRT(srt, attachmentID: id)
        XCTAssertEqual(store.loadSRT(for: id), srt)
    }

    // loadSRT falls through encoders for non-UTF-8 files. UTF-16 with BOM exercises the
    // fallback chain that exists because users sometimes import SRT files exported by Windows
    // tools that default to UTF-16 LE with BOM. Pinning the fallback chain means a future
    // "just use UTF-8" simplification would have to consciously break this case.
    func testLoadSRTDecodesUtf16FallbackWhenNotUtf8() throws {
        let id = UUID()
        let srtText = "1\n00:00:00,000 --> 00:00:01,000\nテスト\n"
        let url = testRoot.appendingPathComponent("\(id.uuidString).srt")
        let data = srtText.data(using: .utf16)! // UTF-16 with BOM
        try data.write(to: url)
        XCTAssertEqual(store.loadSRT(for: id), srtText)
    }

    // loadSRT returns nil when no SRT exists — distinguishes "no subtitles" from "subtitles
    // present but empty string", which is meaningful for the share-sheet export pipeline.
    func testLoadSRTMissingReturnsNil() {
        XCTAssertNil(store.loadSRT(for: UUID()))
    }

    // exportAttachment returns nil when no audio file exists. The backup pipeline uses this
    // signal to decide whether the attachment is "real" enough to include in the snapshot.
    func testExportAttachmentReturnsNilWhenNoAudio() {
        XCTAssertNil(store.exportAttachment(for: UUID()))
    }

    // importAttachment is idempotent: running it twice with the same backup produces an
    // identical file listing. Restoring a backup over an existing install must not accumulate
    // duplicate files or break per-attachment lookup.
    func testImportAttachmentIsIdempotent() throws {
        let id = UUID()
        let backup = AudioAttachmentBackup(
            attachmentID: id,
            audioFilename: "song.mp3",
            audioData: Data("fake-mp3-bytes".utf8),
            srtText: "1\n00:00:00,000 --> 00:00:01,000\nhi\n",
            cues: [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "hi")],
            timings: nil
        )
        try store.importAttachment(backup)
        let after1 = try FileManager.default.contentsOfDirectory(atPath: testRoot.path).sorted()

        try store.importAttachment(backup)
        let after2 = try FileManager.default.contentsOfDirectory(atPath: testRoot.path).sorted()

        XCTAssertEqual(after1, after2, "Second import should produce the same file listing as the first")
    }

    // Regression: importAttachment with both audio and SRT must keep the audio bytes intact
    // and produce a separately-loadable SRT. Previously saveSRT extracted the extension from
    // the preferredFilename it was handed, so passing "song.mp3" caused the SRT to be written
    // to a "{uuid}-song.mp3" path that collided with — and overwrote — the audio file. The fix
    // routes through preferredSubtitleFilename(forAudioFilename:) so the SRT lands on ".srt".
    func testImportAttachmentWithAudioAndSRTKeepsBothIntact() throws {
        let id = UUID()
        let audioBytes = Data("fake-mp3-bytes-distinct-marker".utf8)
        let srt = "1\n00:00:00,000 --> 00:00:01,000\nhi\n"
        let backup = AudioAttachmentBackup(
            attachmentID: id,
            audioFilename: "song.mp3",
            audioData: audioBytes,
            srtText: srt,
            cues: nil,
            timings: nil
        )
        try store.importAttachment(backup)

        let resolvedAudio = try XCTUnwrap(store.audioURL(for: id), "audio file must exist after import")
        XCTAssertEqual(
            try Data(contentsOf: resolvedAudio),
            audioBytes,
            "audio bytes must not be overwritten by the SRT save"
        )
        XCTAssertEqual(store.loadSRT(for: id), srt, "SRT must round-trip via loadSRT")
    }

    // importAttachment with timings=nil must clear any stale .timings.json on disk. The
    // production-file comment calls this out: restoring an older backup over an attachment
    // that had karaoke checkpoints would otherwise leave the stale file and loadCueTimings
    // would keep returning the old data.
    func testImportAttachmentClearsStaleTimingsWhenBackupHasNone() throws {
        let id = UUID()
        try store.saveCueTimings(
            [1: [CueCharTiming(timeMs: 0, charOffsetInCue: 0, charLength: 1)]],
            attachmentID: id
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.cueTimingsURL(for: id).path))

        let backup = AudioAttachmentBackup(
            attachmentID: id,
            audioFilename: "song.mp3",
            audioData: Data("bytes".utf8),
            srtText: nil,
            cues: nil,
            timings: nil
        )
        try store.importAttachment(backup)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.cueTimingsURL(for: id).path),
            "importAttachment must remove stale .timings.json when backup carries no timings"
        )
        XCTAssertTrue(store.loadCueTimings(for: id).isEmpty)
    }

    // exportAttachment -> importAttachment round-trips the audio bytes, SRT text, cues, and
    // timings into a fresh store rooted at a different directory — simulating restoring on
    // a clean install. Pins the whole backup contract end-to-end.
    func testExportImportRoundTripPreservesAllArtifacts() throws {
        let originID = UUID()
        let audioBytes = Data("fake-mp3-content".utf8)
        let audioURL = testRoot.appendingPathComponent("\(originID.uuidString)-song.mp3")
        try audioBytes.write(to: audioURL)
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "hi")]
        let timings: CueCharTimings = [
            1: [CueCharTiming(timeMs: 200, charOffsetInCue: 0, charLength: 1)],
        ]
        try store.saveCues(cues, attachmentID: originID)
        try store.saveCueTimings(timings, attachmentID: originID)
        _ = try store.saveSRT(
            "1\n00:00:00,000 --> 00:00:01,000\nhi\n",
            attachmentID: originID,
            preferredFilename: "song.srt"
        )

        let backup = try XCTUnwrap(store.exportAttachment(for: originID))

        let restoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-audio-tests-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: restoreRoot) }
        let restored = NotesAudioStore(audioDirectory: restoreRoot)
        try restored.importAttachment(backup)

        XCTAssertEqual(restored.loadCues(for: backup.attachmentID), cues)
        XCTAssertEqual(restored.loadCueTimings(for: backup.attachmentID), timings)
        let restoredAudio = try XCTUnwrap(restored.audioURL(for: backup.attachmentID))
        XCTAssertEqual(try Data(contentsOf: restoredAudio), audioBytes)
        XCTAssertEqual(restored.loadSRT(for: backup.attachmentID), "1\n00:00:00,000 --> 00:00:01,000\nhi\n")
    }

    // deleteAttachment removes both UUID-prefixed stored files AND legacy bare-UUID files —
    // the legacy path predates the per-attachment prefix scheme, and skipping it would leave
    // orphan audio bytes on devices upgraded from older builds.
    func testDeleteAttachmentRemovesUuidPrefixedAndLegacyFiles() throws {
        let id = UUID()
        let modernAudio = testRoot.appendingPathComponent("\(id.uuidString)-song.mp3")
        try Data("a".utf8).write(to: modernAudio)
        let legacyAudio = testRoot.appendingPathComponent("\(id.uuidString).m4a")
        try Data("b".utf8).write(to: legacyAudio)
        try store.saveCues([SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "hi")], attachmentID: id)
        try store.saveCueTimings(
            [1: [CueCharTiming(timeMs: 0, charOffsetInCue: 0, charLength: 1)]],
            attachmentID: id
        )
        _ = try store.saveSRT("hi", attachmentID: id)

        store.deleteAttachment(id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modernAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.cueTimingsURL(for: id).path))
        XCTAssertNil(store.audioURL(for: id))
        XCTAssertNil(store.subtitleURL(for: id))
    }

    // audioURL falls back to a bare "{uuid}.ext" file when no UUID-prefixed file is present.
    // Without this fallback, audio files written by older app versions become invisible after
    // an upgrade — same data, different filename scheme.
    func testAudioURLFindsLegacyBareUuidFile() throws {
        let id = UUID()
        let legacy = testRoot.appendingPathComponent("\(id.uuidString).m4a")
        try Data("legacy".utf8).write(to: legacy)
        XCTAssertEqual(store.audioURL(for: id), legacy)
    }

    // saveAudio rewrites the destination when an existing file is present, so re-importing
    // the same audio for the same attachment ID doesn't leave the original bytes intact.
    func testSaveAudioOverwritesExistingFile() throws {
        let id = UUID()
        let source1 = testRoot.appendingPathComponent("source1.mp3")
        try Data("first".utf8).write(to: source1)
        let dest1 = try store.saveAudio(from: source1, attachmentID: id)
        XCTAssertEqual(try Data(contentsOf: dest1), Data("first".utf8))

        let source2 = testRoot.appendingPathComponent("source2.mp3")
        try Data("second".utf8).write(to: source2)
        let dest2 = try store.saveAudio(from: source2, attachmentID: id)
        XCTAssertEqual(try Data(contentsOf: dest2), Data("second".utf8))
    }

    // preferredSubtitleFilename(forAudioFilename:) is the static helper the bulk-import
    // pipeline uses to predict the SRT filename paired with an audio file. Pure function;
    // worth pinning because BulkImport's pairing logic and importAttachment's SRT naming
    // both depend on it producing the expected ".srt" companion.
    func testPreferredSubtitleFilenameDerivesFromAudioFilename() {
        XCTAssertEqual(NotesAudioStore.preferredSubtitleFilename(forAudioFilename: "song.mp3"), "song.srt")
        XCTAssertEqual(NotesAudioStore.preferredSubtitleFilename(forAudioFilename: "song.m4a"), "song.srt")
        XCTAssertEqual(NotesAudioStore.preferredSubtitleFilename(forAudioFilename: "no-extension"), "no-extension.srt")
        XCTAssertEqual(NotesAudioStore.preferredSubtitleFilename(forAudioFilename: "  spaces  "), "spaces.srt")
        XCTAssertEqual(NotesAudioStore.preferredSubtitleFilename(forAudioFilename: ""), "subtitles.srt")
    }

    // preferredSubtitleExportFilename uses the SRT's own basename when an SRT exists — this
    // is what the user sees in the share-sheet save dialog, and matching the source filename
    // is the trust-preserving default (no surprise renames).
    func testPreferredSubtitleExportFilenameUsesSRTBasenameWhenPresent() throws {
        let id = UUID()
        _ = try store.saveSRT("hi", attachmentID: id, preferredFilename: "my-song.srt")
        XCTAssertEqual(store.preferredSubtitleExportFilename(for: id), "my-song.srt")
    }

    // Falls back to a UUID-based filename when neither audio nor SRT exists — last resort so
    // export never produces an empty or duplicate filename.
    func testPreferredSubtitleExportFilenameFallsBackToUUIDWhenNoFiles() {
        let id = UUID()
        XCTAssertEqual(store.preferredSubtitleExportFilename(for: id), "\(id.uuidString).srt")
    }
}
