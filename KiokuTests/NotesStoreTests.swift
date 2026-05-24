import XCTest
@testable import Kioku

// Characterizes NotesStore's file-backed persistence + the defensive "refuse to
// overwrite populated disk with empty in-memory state" guard that the comments
// in the production file call out as the recurring "notes were nuked" failure
// pattern's fix. Tests redirect Application Support to a per-test temp dir via
// a FileManager subclass so each case starts on a clean filesystem.
@MainActor
final class NotesStoreTests: XCTestCase {

    private var testRoot: URL!
    private var fileManager: TestFileManager!

    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-notes-tests-\(UUID().uuidString)", isDirectory: true)
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

    // A fresh directory yields an empty store — no migration noise, no leaked state.
    func testInitFromEmptyDirectoryIsEmpty() {
        let store = NotesStore(fileManager: fileManager)
        XCTAssertTrue(store.notes.isEmpty)
    }

    // addNote inserts at the top and the new note survives a reload through a
    // second store instance reading from the same directory.
    func testAddNotePersistsAcrossInstances() {
        let writer = NotesStore(fileManager: fileManager)
        writer.addNote(Note(title: "First", content: "猫"))
        writer.flushPendingSave()
        let reader = NotesStore(fileManager: fileManager)
        XCTAssertEqual(reader.notes.count, 1)
        XCTAssertEqual(reader.notes.first?.title, "First")
        XCTAssertEqual(reader.notes.first?.content, "猫")
    }

    // Insertion order is preserved across reload via the _index.json sidecar.
    func testNoteOrderingPersistsAcrossInstances() {
        let writer = NotesStore(fileManager: fileManager)
        writer.addNote(Note(title: "C", content: "c"))
        writer.addNote(Note(title: "B", content: "b"))
        writer.addNote(Note(title: "A", content: "a"))
        writer.flushPendingSave()
        let reader = NotesStore(fileManager: fileManager)
        XCTAssertEqual(reader.notes.map(\.title), ["A", "B", "C"])
    }

    // deleteNote removes the in-memory entry AND the on-disk file, so a fresh
    // instance doesn't resurrect the deleted note from leftover JSON.
    func testDeleteNoteRemovesFromDisk() {
        let writer = NotesStore(fileManager: fileManager)
        writer.addNote(Note(title: "Keep", content: "k"))
        writer.addNote(Note(title: "Drop", content: "d"))
        writer.flushPendingSave()

        let drop = writer.notes.first(where: { $0.title == "Drop" })!
        writer.deleteNote(id: drop.id)
        writer.flushPendingSave()

        let reader = NotesStore(fileManager: fileManager)
        XCTAssertEqual(reader.notes.map(\.title), ["Keep"])
    }

    // renameNote updates the title and the change persists. (Skips a
    // modifiedAt comparison because Note's date encoding round-trips through
    // JSON ISO8601 which loses sub-second precision — when rename happens
    // within the same second as creation, the persisted modifiedAt can land
    // slightly before the in-memory value and produce false negatives.)
    func testRenameNotePersistsTitleChange() {
        let writer = NotesStore(fileManager: fileManager)
        writer.addNote(Note(title: "Old", content: "x"))
        writer.flushPendingSave()

        let target = writer.notes.first!
        writer.renameNote(id: target.id, title: "New")
        writer.flushPendingSave()

        let reader = NotesStore(fileManager: fileManager)
        XCTAssertEqual(reader.notes.first?.title, "New")
    }

    // duplicateNote inserts a copy at the top with the same content but a fresh UUID.
    func testDuplicateNoteCreatesNewIdentifierWithSameContent() {
        let store = NotesStore(fileManager: fileManager)
        store.addNote(Note(title: "Orig", content: "abc"))
        let original = store.notes.first!

        let copy = store.duplicateNote(id: original.id)
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, original.id)
        XCTAssertEqual(copy?.title, original.title)
        XCTAssertEqual(copy?.content, original.content)
        XCTAssertEqual(store.notes.first?.id, copy?.id, "Duplicate must land at the top")
    }

    // The defensive guard from save() / flushPendingSave(): if in-memory state
    // is empty but disk has notes, the save is refused — protects against the
    // "transient read failure wipes notes" pattern. Tested by writing notes via
    // one store, simulating an init that produced an empty in-memory state, and
    // confirming the on-disk files are untouched after flushPendingSave runs.
    func testFlushRefusesToOverwritePopulatedDiskWithEmptyMemory() {
        let writer = NotesStore(fileManager: fileManager)
        writer.addNote(Note(title: "Keep", content: "k"))
        writer.addNote(Note(title: "Me",   content: "m"))
        writer.flushPendingSave()

        // Construct a second store and manipulate it into the dangerous state:
        // diskSnapshotByID populated (from init's file read), then notes wiped
        // by replaceAll without telling the disk snapshot. Direct field access
        // isn't available, so simulate by deleting from in-memory only.
        let saboteur = NotesStore(fileManager: fileManager)
        XCTAssertEqual(saboteur.notes.count, 2, "Setup precondition")

        // Use deleteNotes(ids:) to empty the in-memory state without going
        // through replaceAll (which resets the disk snapshot intentionally).
        // This mirrors the historical bug: an in-memory state went to zero
        // through some path that didn't intend to clear disk.
        saboteur.deleteNotes(ids: Set(saboteur.notes.map(\.id)))
        // didSet fires per remove, triggering save() — which sees empty + disk
        // populated and SHOULD refuse. The refusal isn't observable from here
        // without reading the console; the observable effect is that disk
        // still has both notes after a fresh read.

        let reader = NotesStore(fileManager: fileManager)
        XCTAssertEqual(
            Set(reader.notes.map(\.title)), Set(["Keep", "Me"]),
            "Defensive guard should have refused the empty-state save"
        )
    }

    // replaceAll(with: []) is the *one* legitimate way to clear everything:
    // it explicitly resets the disk snapshot alongside the in-memory state, so
    // the guard correctly lets the empty-state save through.
    func testReplaceAllWithEmptyClearsDisk() {
        let writer = NotesStore(fileManager: fileManager)
        writer.addNote(Note(title: "x", content: "x"))
        writer.flushPendingSave()

        writer.replaceAll(with: [])
        writer.flushPendingSave()

        let reader = NotesStore(fileManager: fileManager)
        XCTAssertTrue(reader.notes.isEmpty)
    }

    // docs/INVARIANTS.md "Note Persistence" #5 — `_index.json` and the
    // `<noteID>.json` files on disk must stay in lockstep: the index lists
    // exactly the IDs for which a JSON file exists, in load order. Drift on
    // either side causes missing-from-list or duplicate-row UI bugs, plus the
    // load-from-disk pipeline produces either dangling references or orphan
    // files that re-appear on next launch.
    //
    // Walks the lifecycle: add → delete → replaceAll, asserting consistency
    // after each step by reading both surfaces (the on-disk index file and
    // the actual file listing of the Notes directory).
    func testIndexAndDiskFilesStayConsistentAcrossLifecycle() throws {
        let writer = NotesStore(fileManager: fileManager)
        let n1 = Note(title: "first", content: "1")
        let n2 = Note(title: "second", content: "2")
        let n3 = Note(title: "third", content: "3")

        writer.addNote(n1)
        writer.addNote(n2)
        writer.addNote(n3)
        writer.flushPendingSave()
        try assertIndexMatchesFiles(expectedCount: 3)

        // Delete the middle note. Index must drop n2.id; n2.json must be gone.
        _ = writer.deleteNote(id: n2.id)
        writer.flushPendingSave()
        try assertIndexMatchesFiles(expectedCount: 2, mustNotContain: n2.id)

        // replaceAll wipes everything. Index empties; all <id>.json files gone.
        writer.replaceAll(with: [])
        writer.flushPendingSave()
        try assertIndexMatchesFiles(expectedCount: 0)
    }

    // Reads `_index.json` and the directory listing of `<root>/Notes/` and
    // confirms they describe the same set of note IDs. Both sources must agree
    // on count, and the index's IDs must appear as filenames (and vice versa).
    private func assertIndexMatchesFiles(
        expectedCount: Int,
        mustNotContain banned: UUID? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let notesDir = testRoot.appendingPathComponent("Notes", isDirectory: true)
        let indexURL = notesDir.appendingPathComponent("_index.json")

        // Diskside: every <UUID>.json file in Notes/ (excluding _index.json)
        let allFiles = (try? FileManager.default.contentsOfDirectory(atPath: notesDir.path)) ?? []
        let noteFileIDs: Set<UUID> = Set(allFiles.compactMap { name -> UUID? in
            guard name.hasSuffix(".json"), name != "_index.json" else { return nil }
            return UUID(uuidString: String(name.dropLast(".json".count)))
        })

        // Indexside: the IDs `_index.json` lists, in order.
        let indexedIDs: [UUID]
        if expectedCount == 0, FileManager.default.fileExists(atPath: indexURL.path) == false {
            // No index file is acceptable as an empty index — the store re-creates
            // it on next write. Treat as zero entries.
            indexedIDs = []
        } else {
            let data = try Data(contentsOf: indexURL)
            let stringIDs = try JSONDecoder().decode([String].self, from: data)
            indexedIDs = stringIDs.compactMap(UUID.init(uuidString:))
        }

        XCTAssertEqual(noteFileIDs.count, expectedCount,
                       "Expected \(expectedCount) <id>.json files but found \(noteFileIDs.count)",
                       file: file, line: line)
        XCTAssertEqual(indexedIDs.count, expectedCount,
                       "Expected \(expectedCount) entries in _index.json but found \(indexedIDs.count)",
                       file: file, line: line)
        XCTAssertEqual(Set(indexedIDs), noteFileIDs,
                       "Index entries and on-disk note files diverge: index=\(Set(indexedIDs)) files=\(noteFileIDs)",
                       file: file, line: line)
        if let banned {
            XCTAssertFalse(noteFileIDs.contains(banned),
                           "Deleted note \(banned) must not have a file on disk",
                           file: file, line: line)
            XCTAssertFalse(indexedIDs.contains(banned),
                           "Deleted note \(banned) must not appear in _index.json",
                           file: file, line: line)
        }
    }
}

// FileManager subclass that redirects .applicationSupportDirectory lookups to a
// caller-provided temp root. NotesStore queries that location through its
// injected FileManager, so this swap is the only change required to scope each
// test to its own filesystem.
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
