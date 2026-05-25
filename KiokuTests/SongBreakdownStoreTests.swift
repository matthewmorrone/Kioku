import XCTest
@testable import Kioku

// Characterizes SongBreakdownStore's two-tier cache (published + memo + disk), the disk
// persistence and self-heal-on-read integration with SongBreakdownRecovery, the staleness
// detection via sourceTextHash, and the generation-state machine for cancel/error-clear.
// Generation itself (the LLM dispatch) isn't tested here — it's covered indirectly by the
// service-level integration tests and would need a protocol extraction on
// SongBreakdownService to mock cleanly.
//
// Each test redirects .applicationSupportDirectory to a per-case temp dir via a
// TestFileManager subclass, mirroring the NotesStoreTests isolation pattern.
@MainActor
final class SongBreakdownStoreTests: XCTestCase {

    private var testRoot: URL!
    private var fileManager: TestFileManager!

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-songbreakdown-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testRoot = root
        fileManager = TestFileManager(testRoot: root)
    }

    override func tearDown() async throws {
        if let testRoot, FileManager.default.fileExists(atPath: testRoot.path) {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
        fileManager = nil
        try await super.tearDown()
    }

    private func makeStore() -> SongBreakdownStore {
        SongBreakdownStore(fileManager: fileManager)
    }

    // Builds a non-trivial breakdown with the supplied note id, text hash, and one line.
    private func makeBreakdown(
        noteID: UUID,
        sourceTextHash: String = "hash-1",
        provider: SongBreakdownProvider = .stub
    ) -> SongBreakdown {
        SongBreakdown(
            noteID: noteID,
            sourceTextHash: sourceTextHash,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: provider,
            lines: [
                SongLine(
                    index: 1,
                    original: "猫がいる",
                    romaji: "neko ga iru",
                    words: [
                        SongWord(surface: "猫", sungRomaji: "neko", definition: "cat"),
                        SongWord(surface: "いる", sungRomaji: "iru", definition: "to exist"),
                    ],
                    gist: "There's a cat.",
                    grammarNote: nil,
                    reference: nil
                ),
            ]
        )
    }

    // MARK: - Initialization

    // A fresh suite produces an empty published cache. The store has no breakdowns to surface
    // until either set/clear is called or a disk read faults one in.
    func testInitFromEmptyStorageHasEmptyPublishedCache() {
        let store = makeStore()
        XCTAssertTrue(store.breakdownsByNoteID.isEmpty)
    }

    // MARK: - setBreakdown

    // setBreakdown publishes the value AND writes it to disk synchronously, so the next
    // launch sees it immediately via the disk-scan-and-fault-in path.
    func testSetBreakdownPublishesAndPersists() throws {
        let writer = makeStore()
        let id = UUID()
        let breakdown = makeBreakdown(noteID: id)

        writer.setBreakdown(breakdown)
        XCTAssertEqual(writer.breakdownsByNoteID[id], breakdown)

        // A fresh reader scans the disk on init and recognizes the id; the breakdown faults
        // in via breakdown(forNoteID:) without needing setBreakdown.
        let reader = makeStore()
        XCTAssertTrue(reader.breakdownsByNoteID.isEmpty, "disk-backed entries aren't published until faulted in")
        XCTAssertEqual(reader.breakdown(forNoteID: id), breakdown)
    }

    // MARK: - clearBreakdown

    // clearBreakdown drops the published entry AND the disk file. The next reader doesn't
    // know about the id at all — the disk scan finds nothing.
    func testClearBreakdownRemovesFromPublishedAndDisk() {
        let store = makeStore()
        let id = UUID()
        store.setBreakdown(makeBreakdown(noteID: id))
        store.clearBreakdown(forNoteID: id)
        XCTAssertNil(store.breakdownsByNoteID[id])
        XCTAssertNil(store.breakdown(forNoteID: id))

        let reader = makeStore()
        XCTAssertNil(reader.breakdown(forNoteID: id))
    }

    // MARK: - breakdown(forNoteID:) lookup tiers

    // The lookup walks published → memo → disk. After a disk read, the value lands in the
    // memo, NOT the published cache (to avoid "publishing changes from within view updates").
    func testBreakdownLookupFaultsDiskIntoMemoNotPublished() {
        let id = UUID()
        let writer = makeStore()
        writer.setBreakdown(makeBreakdown(noteID: id))

        let reader = makeStore()
        XCTAssertNil(reader.breakdownsByNoteID[id], "disk hit must not populate the published cache")
        XCTAssertNotNil(reader.breakdown(forNoteID: id))
        // Second read still doesn't publish — memo caches it but the published dict stays empty.
        _ = reader.breakdown(forNoteID: id)
        XCTAssertNil(reader.breakdownsByNoteID[id])
    }

    // breakdown returns nil for unknown ids and never throws or crashes.
    func testBreakdownReturnsNilForUnknownNote() {
        XCTAssertNil(makeStore().breakdown(forNoteID: UUID()))
    }

    // MARK: - isStale / hasFreshBreakdown

    // Matching hash → fresh; mismatched hash → stale; no breakdown at all → neither.
    func testStalenessReportingForExistingBreakdown() {
        let id = UUID()
        let store = makeStore()
        store.setBreakdown(makeBreakdown(noteID: id, sourceTextHash: "hash-1"))

        XCTAssertTrue(store.hasFreshBreakdown(forNoteID: id, currentTextHash: "hash-1"))
        XCTAssertFalse(store.isStale(forNoteID: id, currentTextHash: "hash-1"))

        XCTAssertFalse(store.hasFreshBreakdown(forNoteID: id, currentTextHash: "hash-2"))
        XCTAssertTrue(store.isStale(forNoteID: id, currentTextHash: "hash-2"))
    }

    // No breakdown at all → not stale (nothing to compare against). Mirrors the production
    // comment: the staleness banner should only fire when there's actually a breakdown to
    // be stale against; absence is the "go generate" state, not the "regenerate" state.
    func testIsStaleReturnsFalseWhenNoBreakdownExists() {
        let store = makeStore()
        XCTAssertFalse(store.isStale(forNoteID: UUID(), currentTextHash: "any"))
        XCTAssertFalse(store.hasFreshBreakdown(forNoteID: UUID(), currentTextHash: "any"))
    }

    // MARK: - Disk self-heal on read

    // Disk reads pass through SongBreakdownRecovery; the legacy "all lines collapsed into
    // line 1" shape gets re-split on faulting in. The healed value is also written back
    // to disk so the next read skips the recovery pass entirely.
    func testReadFromDiskAppliesRecoveryAndWritesHealedValueBack() throws {
        // Write a "legacy" breakdown directly to disk: trailing lines collapsed into a single
        // grammar-note string on line 1. SongBreakdownRecovery looks for the actual leaked-
        // header markdown shape (`**Line N: <jp>**` optionally followed by `*<romaji>*`).
        let id = UUID()
        let leakedGrammar = """
        **Line 2: 犬がいる** *inu ga iru*
        **Line 3: 鳥がいる** *tori ga iru*
        """
        let legacy = SongBreakdown(
            noteID: id,
            sourceTextHash: "hash-legacy",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .stub,
            lines: [
                SongLine(
                    index: 1,
                    original: "猫がいる",
                    romaji: nil,
                    words: [],
                    gist: nil,
                    grammarNote: leakedGrammar,
                    reference: nil
                ),
            ]
        )

        // Force the legacy shape onto disk by routing through SongBreakdownStore's writer,
        // bypassing the recovery pass (recovery only runs on read).
        let seedStore = makeStore()
        seedStore.setBreakdown(legacy)

        // A new store reads from disk through breakdown(forNoteID:), which runs recovery.
        let reader = makeStore()
        let healed = try XCTUnwrap(reader.breakdown(forNoteID: id))
        XCTAssertGreaterThan(healed.lines.count, 1, "recovery should split the leaked grammar note back into separate lines")

        // After the heal, the on-disk JSON is the healed shape — the next reader sees the
        // multi-line breakdown immediately without needing to run recovery again.
        let secondReader = makeStore()
        let secondRead = try XCTUnwrap(secondReader.breakdown(forNoteID: id))
        XCTAssertEqual(secondRead, healed)
    }

    // MARK: - Generation state machine (without invoking the network)

    // cancelGeneration on a note that has no in-flight generation is a no-op.
    func testCancelGenerationOnIdleNoteIsNoOp() {
        let store = makeStore()
        store.cancelGeneration(forNoteID: UUID())
        XCTAssertTrue(store.generationStateByNoteID.isEmpty)
    }

    // clearGenerationError on a non-failed state is a no-op — protects callers from
    // accidentally wiping a running state via the Retry button.
    func testClearGenerationErrorOnIdleNoteIsNoOp() {
        let store = makeStore()
        let id = UUID()
        store.clearGenerationError(forNoteID: id)
        XCTAssertNil(store.generationStateByNoteID[id])
    }

    // isGenerating returns false for any note that has neither a running task nor any
    // state at all.
    func testIsGeneratingReturnsFalseForIdleNotes() {
        XCTAssertFalse(makeStore().isGenerating(forNoteID: UUID()))
    }
}

// FileManager subclass that redirects .applicationSupportDirectory lookups to a caller-
// provided temp root. SongBreakdownStore queries that location through its injected
// FileManager, so this swap scopes each test to its own filesystem.
private final class TestFileManager: FileManager {
    private let testRoot: URL

    init(testRoot: URL) {
        self.testRoot = testRoot
        super.init()
    }

    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        if directory == .applicationSupportDirectory {
            if shouldCreate, fileExists(atPath: testRoot.path) == false {
                try createDirectory(at: testRoot, withIntermediateDirectories: true)
            }
            return testRoot
        }
        return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }
}
