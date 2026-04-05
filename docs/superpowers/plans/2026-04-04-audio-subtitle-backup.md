# Audio & Subtitle Backup/Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Include audio files, SRT subtitle files, and subtitle cue JSON in the full-app backup/restore flow so that notes with audio attachments survive an export/import cycle intact.

**Architecture:** The backup format bumps to version 2 and gains a `audioAttachments` array in `AppBackupPayload`. Each entry carries the attachment UUID, the audio file as base64 data, the raw SRT text (if present), and the decoded cue list. On export, `NotesAudioStore` is queried for each note's `audioAttachmentID`. On import, the audio file and subtitle data are written back to `Documents/audio/` before the notes are restored, so the existing playback path needs no changes. Notes-only transfer (`NotesTransferPayload`) is left unchanged — audio is heavy and the notes-export format is intentionally lightweight.

**Tech Stack:** Swift, Foundation, SwiftUI, `NotesAudioStore` (existing), `AppBackupPayload` (existing), `AppBackupDocument` (existing), `SettingsView` (existing)

---

## File Map

| File | Change |
|------|--------|
| `Kioku/Settings/AppBackupPayload.swift` | Add `audioAttachments: [AudioAttachmentBackup]`, bump `currentVersion` to 2 |
| `Kioku/Settings/AudioAttachmentBackup.swift` | **Create** — pure data struct, Codable |
| `Kioku/Settings/AppBackupDocument.swift` | Update version guard for version 2; keep version 1 import working (no audio restored for v1) |
| `Kioku/Read/Audio/NotesAudioStore.swift` | Add `exportAttachment(for:)` and `importAttachment(_:)` helpers |
| `Kioku/Settings/SettingsView.swift` | Update `beginAppExport()` and `importAppBackup(_:)` to handle audio; update success message |

---

### Task 1: AudioAttachmentBackup data struct

**Files:**
- Create: `Kioku/Settings/AudioAttachmentBackup.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

// Serializable snapshot of one audio attachment for inclusion in a full-app backup.
// Carries the UUID that links the attachment to its Note, the raw audio bytes, optional
// SRT text, and the decoded cue list so playback works immediately after restore.
struct AudioAttachmentBackup: Codable, Equatable {
    // UUID matching Note.audioAttachmentID.
    var attachmentID: UUID
    // Original audio filename (e.g. "song.mp3") — used to reconstruct the stored filename.
    var audioFilename: String
    // Raw audio file bytes, base64-encoded by JSONEncoder automatically via Data.
    var audioData: Data
    // Raw SRT text — nil when no subtitle file exists for this attachment.
    var srtText: String?
    // Decoded subtitle cues — nil when no cues have been generated.
    var cues: [SubtitleCue]?
}
```

- [ ] **Step 2: Verify the file compiles**

Open the file in Xcode or run a build. No test needed for a pure data struct.

- [ ] **Step 3: Commit**

```bash
git add Kioku/Settings/AudioAttachmentBackup.swift
git commit -m "feat: add AudioAttachmentBackup codable struct for backup payload"
```

---

### Task 2: AppBackupPayload — add audioAttachments, bump version

**Files:**
- Modify: `Kioku/Settings/AppBackupPayload.swift`

- [ ] **Step 1: Update the payload**

Replace the entire file content:

```swift
import Foundation

// Versioned full-app backup payload covering all persisted Kioku user data.
nonisolated struct AppBackupPayload: Codable {
    static let currentVersion = 2

    var version: Int
    var exportedAt: Date
    var notes: [Note]
    var words: [SavedWord]
    var wordLists: [WordList]
    var history: [HistoryEntry]
    var reviewStats: [AppBackupReviewStats]
    var markedWrong: [Int64]
    var lifetimeCorrect: Int
    var lifetimeAgain: Int
    // Audio file bytes, SRT text, and cues for notes that have audio attachments.
    // Empty array when no audio attachments exist.
    var audioAttachments: [AudioAttachmentBackup]

    // Creates a full backup payload from the current in-memory stores.
    init(
        version: Int = currentVersion,
        exportedAt: Date = Date(),
        notes: [Note],
        words: [SavedWord],
        wordLists: [WordList],
        history: [HistoryEntry],
        reviewStats: [AppBackupReviewStats],
        markedWrong: [Int64],
        lifetimeCorrect: Int,
        lifetimeAgain: Int,
        audioAttachments: [AudioAttachmentBackup] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.notes = notes
        self.words = words
        self.wordLists = wordLists
        self.history = history
        self.reviewStats = reviewStats
        self.markedWrong = markedWrong
        self.lifetimeCorrect = lifetimeCorrect
        self.lifetimeAgain = lifetimeAgain
        self.audioAttachments = audioAttachments
    }
}
```

- [ ] **Step 2: Verify the build still compiles**

The `SettingsView` initializer for `AppBackupPayload` uses default parameter order — the new `audioAttachments` parameter has a default value of `[]` so existing call sites won't break.

- [ ] **Step 3: Commit**

```bash
git add Kioku/Settings/AppBackupPayload.swift
git commit -m "feat: add audioAttachments field to AppBackupPayload, bump version to 2"
```

---

### Task 3: AppBackupDocument — support version 1 and version 2

**Files:**
- Modify: `Kioku/Settings/AppBackupDocument.swift`

Currently the version guard rejects anything that isn't `currentVersion`. After the bump, a version 1 backup (no audio) should still import cleanly by synthesizing an empty `audioAttachments` array.

- [ ] **Step 1: Update decodePayload**

Replace `decodePayload(from:)`:

```swift
// Decodes the current versioned app-backup payload format.
// Version 1 backups (no audio) are accepted and upgraded — audioAttachments defaults to [].
private static func decodePayload(from data: Data) throws -> AppBackupPayload {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let payload = try decoder.decode(AppBackupPayload.self, from: data)
    guard payload.version == AppBackupPayload.currentVersion || payload.version == 1 else {
        throw NSError(
            domain: "Kioku.AppBackup",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unsupported app backup version \(payload.version). Expected version \(AppBackupPayload.currentVersion)."]
        )
    }
    return payload
}
```

Because `audioAttachments` has a default value in the struct init and JSONDecoder will leave it as `[]` when the key is absent (Swift synthesised Codable uses optional decoding for missing keys when a default init exists — but to be safe, make the property optional in the payload or use a custom decode). 

Actually, since `AppBackupPayload` uses synthesised `Codable`, a missing key for a non-optional property will throw. Use a custom `init(from:)` decoder to handle the missing key gracefully:

- [ ] **Step 2: Add CodingKeys + custom decoder to AppBackupPayload**

Append to `AppBackupPayload.swift` (inside the struct, after the memberwise init):

```swift
    private enum CodingKeys: String, CodingKey {
        case version, exportedAt, notes, words, wordLists, history
        case reviewStats, markedWrong, lifetimeCorrect, lifetimeAgain
        case audioAttachments
    }

    // Custom decoder so version-1 backups (no audioAttachments key) decode cleanly.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        notes = try c.decode([Note].self, forKey: .notes)
        words = try c.decode([SavedWord].self, forKey: .words)
        wordLists = try c.decode([WordList].self, forKey: .wordLists)
        history = try c.decode([HistoryEntry].self, forKey: .history)
        reviewStats = try c.decode([AppBackupReviewStats].self, forKey: .reviewStats)
        markedWrong = try c.decode([Int64].self, forKey: .markedWrong)
        lifetimeCorrect = try c.decode(Int.self, forKey: .lifetimeCorrect)
        lifetimeAgain = try c.decode(Int.self, forKey: .lifetimeAgain)
        audioAttachments = (try? c.decode([AudioAttachmentBackup].self, forKey: .audioAttachments)) ?? []
    }
```

- [ ] **Step 3: Commit**

```bash
git add Kioku/Settings/AppBackupPayload.swift Kioku/Settings/AppBackupDocument.swift
git commit -m "feat: allow version-1 backup imports, gracefully decode missing audioAttachments"
```

---

### Task 4: NotesAudioStore — export and import helpers

**Files:**
- Modify: `Kioku/Read/Audio/NotesAudioStore.swift`

- [ ] **Step 1: Add exportAttachment(for:)**

Add after `loadSRT(for:)`:

```swift
// Reads all files for one attachment and returns a backup snapshot.
// Returns nil if no audio file exists for the attachment (nothing to back up).
func exportAttachment(for attachmentID: UUID) -> AudioAttachmentBackup? {
    guard let audioURL = audioURL(for: attachmentID) else { return nil }
    guard let audioData = try? Data(contentsOf: audioURL) else { return nil }
    let srtText = loadSRT(for: attachmentID)
    let cues = loadCues(for: attachmentID)
    return AudioAttachmentBackup(
        attachmentID: attachmentID,
        audioFilename: readableFilename(fromStoredURL: audioURL, defaultExtension: audioURL.pathExtension),
        audioData: audioData,
        srtText: srtText,
        cues: cues.isEmpty ? nil : cues
    )
}
```

- [ ] **Step 2: Add importAttachment(_:)**

Add after `exportAttachment(for:)`:

```swift
// Writes the audio file, SRT, and cues from a backup snapshot back to disk.
// Safe to call multiple times — existing files are overwritten.
func importAttachment(_ backup: AudioAttachmentBackup) throws {
    // Write audio file using the stored naming convention.
    let ext = (backup.audioFilename as NSString).pathExtension
    let destination = audioDirectory.appendingPathComponent(
        storedFilename(
            attachmentID: backup.attachmentID,
            originalFilename: backup.audioFilename,
            fallbackExtension: ext.isEmpty ? "mp3" : ext
        )
    )
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try backup.audioData.write(to: destination, options: .atomic)

    // Write SRT if present.
    if let srtText = backup.srtText {
        _ = try saveSRT(srtText, attachmentID: backup.attachmentID, preferredFilename: backup.audioFilename)
    }

    // Write cues if present.
    if let cues = backup.cues {
        try saveCues(cues, attachmentID: backup.attachmentID)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Kioku/Read/Audio/NotesAudioStore.swift
git commit -m "feat: add exportAttachment and importAttachment helpers to NotesAudioStore"
```

---

### Task 5: SettingsView — wire export and import

**Files:**
- Modify: `Kioku/Settings/SettingsView.swift`

- [ ] **Step 1: Update beginAppExport() to collect audio attachments**

Replace the `beginAppExport()` function:

```swift
// Captures the latest full app state before presenting the system export flow.
private func beginAppExport() {
    let reviewStats = reviewStore.stats
        .map { AppBackupReviewStats(canonicalEntryID: $0.key, stats: $0.value) }
        .sorted { $0.canonicalEntryID < $1.canonicalEntryID }

    let notes = notesStore.exportNotes()
    let audioStore = NotesAudioStore.shared
    let audioAttachments: [AudioAttachmentBackup] = notes
        .compactMap { $0.audioAttachmentID }
        .compactMap { audioStore.exportAttachment(for: $0) }

    exportDocument = AppBackupDocument(
        payload: AppBackupPayload(
            notes: notes,
            words: wordsStore.words,
            wordLists: wordListsStore.lists,
            history: historyStore.entries,
            reviewStats: reviewStats,
            markedWrong: Array(reviewStore.markedWrong).sorted(),
            lifetimeCorrect: reviewStore.lifetimeCorrect,
            lifetimeAgain: reviewStore.lifetimeAgain,
            audioAttachments: audioAttachments
        )
    )
    isShowingExporter = true
}
```

- [ ] **Step 2: Update importAppBackup(_:) to restore audio before notes**

Replace the `importAppBackup(_:)` function:

```swift
// Applies one validated app-backup snapshot to every persisted store in a single replace-all pass.
// Audio attachments are written to disk before notes are restored so playback paths resolve immediately.
private func importAppBackup(_ document: AppBackupDocument) {
    let payload = document.payload
    let stats = Dictionary(uniqueKeysWithValues: payload.reviewStats.map { ($0.canonicalEntryID, $0.reviewWordStats()) })

    let audioStore = NotesAudioStore.shared
    var audioFailures = 0
    for attachment in payload.audioAttachments {
        do {
            try audioStore.importAttachment(attachment)
        } catch {
            audioFailures += 1
        }
    }

    wordListsStore.replaceAll(with: payload.wordLists)
    wordsStore.replaceAll(with: payload.words)
    historyStore.replaceAll(with: payload.history)
    reviewStore.replaceAll(
        stats: stats,
        markedWrong: Set(payload.markedWrong),
        lifetimeCorrect: payload.lifetimeCorrect,
        lifetimeAgain: payload.lifetimeAgain
    )
    notesStore.replaceAll(with: payload.notes)

    var message = "Imported \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, \(payload.history.count) history entries, and \(payload.reviewStats.count) review records."
    if !payload.audioAttachments.isEmpty {
        let succeeded = payload.audioAttachments.count - audioFailures
        message += " Restored \(succeeded) of \(payload.audioAttachments.count) audio attachment(s)."
    }
    if audioFailures > 0 {
        message += " \(audioFailures) audio file(s) could not be restored."
    }

    showTransferAlert(title: "Import Complete", message: message)
}
```

- [ ] **Step 3: Update the Backup & Restore section footer to mention audio**

Find this line in the `Form`:
```swift
Text("Imports replace notes, saved words, lists, history, and review metrics.")
```

Replace with:
```swift
Text("Imports replace notes (including audio and subtitles), saved words, lists, history, and review metrics.")
```

- [ ] **Step 4: Commit**

```bash
git add Kioku/Settings/SettingsView.swift
git commit -m "feat: include audio attachments in full-app backup export and import"
```

---

## Self-Review

**Spec coverage:** All requirements covered — audio data, SRT, and cues are exported and restored. Version 1 backups continue to work. Notes-only transfer is intentionally unchanged.

**Placeholder scan:** None found.

**Type consistency:**
- `AudioAttachmentBackup` defined in Task 1, used in Tasks 2, 4, 5 ✓
- `exportAttachment(for:)` defined in Task 4, called in Task 5 ✓
- `importAttachment(_:)` defined in Task 4, called in Task 5 ✓
- `storedFilename(attachmentID:originalFilename:fallbackExtension:)` is a private method on `NotesAudioStore` — `importAttachment` is added to the same class so it has access ✓
- `readableFilename(fromStoredURL:defaultExtension:)` is private on `NotesAudioStore` — same class access ✓

**Edge cases handled:**
- Note has `audioAttachmentID` but no file on disk → `exportAttachment` returns nil, attachment is skipped silently
- Audio data write fails on import → counted in `audioFailures`, surfaced in the alert
- Version 1 backup import → `audioAttachments` decodes as `[]`, import loop is a no-op, existing behaviour preserved
