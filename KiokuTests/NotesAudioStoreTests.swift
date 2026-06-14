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

    // Checkpoints ride inside each cue and round-trip through the single cue file. Pins the inline
    // schema so a change to CueCharTiming serialization has to update this test before silently
    // breaking on-disk compatibility.
    func testSaveCuesRoundTripsInlineCheckpoints() throws {
        let id = UUID()
        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "猫", checkpoints: [
                CueCharTiming(timeMs: 0, charOffsetInCue: 0, charLength: 1),
                CueCharTiming(timeMs: 250, charOffsetInCue: 1, charLength: 2),
            ]),
            SubtitleCue(index: 2, startMs: 1000, endMs: 2500, text: "犬", checkpoints: []),
        ]
        try store.saveCues(cues, attachmentID: id)
        XCTAssertEqual(store.loadCues(for: id), cues)
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
            cues: [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "hi")]
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
            cues: nil
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

    // exportAttachment -> importAttachment round-trips the audio bytes, SRT text, and cues (with
    // their inline checkpoints) into a fresh store rooted at a different directory — simulating
    // restoring on a clean install. Pins the whole backup contract end-to-end.
    func testExportImportRoundTripPreservesAllArtifacts() throws {
        let originID = UUID()
        let audioBytes = Data("fake-mp3-content".utf8)
        let audioURL = testRoot.appendingPathComponent("\(originID.uuidString)-song.mp3")
        try audioBytes.write(to: audioURL)
        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "hi", checkpoints: [
                CueCharTiming(timeMs: 200, charOffsetInCue: 0, charLength: 1),
            ]),
        ]
        try store.saveCues(cues, attachmentID: originID)
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
        _ = try store.saveSRT("hi", attachmentID: id)

        store.deleteAttachment(id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modernAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAudio.path))
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
