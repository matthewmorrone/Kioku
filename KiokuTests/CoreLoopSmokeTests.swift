import XCTest
@testable import Kioku

// Smoke test of the core user loop, threaded across the real stores: create a note, save a word
// attributed to it, record a review, and confirm the data stays consistent AND survives fresh
// store instances (the persistence guarantee backup/restore ultimately relies on).
//
// This is a fast integration test through the store APIs, not XCUITest UI automation — a true
// on-device UI smoke test would need a separate UITest target added in Xcode. This covers the
// data loop (notes → lookup/save → study → persistence) that a per-store unit test can't, since
// it exercises the cross-store attribution (SavedWord.sourceNoteIDs ↔ Note.id) end to end.
@MainActor
final class CoreLoopSmokeTests: XCTestCase {
    private var notesRoot: URL!
    private var notesFM: TestFileManager!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-coreloop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        notesRoot = root
        notesFM = TestFileManager(testRoot: root)
        defaultsSuite = "kioku-coreloop-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() async throws {
        if let notesRoot, FileManager.default.fileExists(atPath: notesRoot.path) {
            try? FileManager.default.removeItem(at: notesRoot)
        }
        if let defaultsSuite { defaults?.removePersistentDomain(forName: defaultsSuite) }
        notesRoot = nil; notesFM = nil; defaults = nil; defaultsSuite = nil
        try await super.tearDown()
    }

    // Note → save a word from it → study it → everything stays consistent and reloads intact.
    func testCoreLoopPersistsAcrossStoreInstances() {
        let entryID: Int64 = 4242
        let storageKey = "kioku.words.smoke"

        // 1. Notes: create a note.
        let notes = NotesStore(fileManager: notesFM)
        let note = Note(title: "Song", content: "朽ちた翼")
        notes.addNote(note)
        notes.flushPendingSave()
        XCTAssertTrue(notes.notes.contains { $0.id == note.id }, "note not present after add")

        // 2. Words: save a word attributed to that note (the lookup/save step).
        let words = WordsStore(userDefaults: defaults, storageKey: storageKey)
        words.add(SavedWord(canonicalEntryID: entryID, surface: "朽ちる", sourceNoteIDs: [note.id]))
        WordsStore.flushPendingWritesForTesting()
        XCTAssertEqual(words.words.first?.canonicalEntryID, entryID)
        XCTAssertEqual(words.words.first?.sourceNoteIDs, [note.id], "note attribution missing")

        // 3. Study: record a correct review; the review stats should now track this entry. Since
        // the ReviewStore merge this is the same store the word was saved in — review state is a
        // field on the word row, so recording it anywhere else would have nowhere to land.
        words.recordCorrect(for: entryID)
        XCTAssertNotNil(words.stats[entryID], "review not recorded")

        // 4. Persistence (what backup/restore rests on): fresh store instances still see it all.
        // Flushed first — word writes land on a background queue, so a reader built immediately
        // after the review would read the pre-review snapshot.
        WordsStore.flushPendingWritesForTesting()
        let notes2 = NotesStore(fileManager: notesFM)
        XCTAssertTrue(notes2.notes.contains { $0.id == note.id }, "note lost on reload")

        let words2 = WordsStore(userDefaults: defaults, storageKey: storageKey)
        XCTAssertEqual(words2.words.first?.canonicalEntryID, entryID, "saved word lost on reload")
        XCTAssertEqual(words2.words.first?.sourceNoteIDs, [note.id], "note attribution lost on reload")

        XCTAssertNotNil(words2.stats[entryID], "review stats lost on reload")
    }
}

// Redirects Application Support to a per-test temp dir so NotesStore's file-backed persistence
// stays isolated (mirrors the private helper in NotesStoreTests/SongBreakdownStoreTests).
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
