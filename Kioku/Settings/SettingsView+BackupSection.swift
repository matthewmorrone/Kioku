import Foundation
import UniformTypeIdentifiers

// Backup export/import logic, extracted from SettingsView to keep the parent file under the
// project's 1000-line invariant. All @State / @EnvironmentObject this extension touches are
// declared non-private on SettingsView specifically so this file can reach them — see the "Not
// private" comments at each property's declaration site.
extension SettingsView {
    // Captures the latest full app state and presents the system export flow. With audio or stems
    // chosen, the files are staged and zipped off the main thread first, so a large library does
    // not freeze Settings.
    func beginAppExport() {
        let reviewStats = wordsStore.stats
            .map { AppBackupReviewStats(canonicalEntryID: $0.key, stats: $0.value) }
            .sorted { $0.canonicalEntryID < $1.canonicalEntryID }

        let notes = notesStore.exportNotes()
        let audioStore = NotesAudioStore.shared
        let options = exportOptions
        // Audio bytes never go into the JSON: they travel as files in the zip, or not at all. The
        // attachment records still carry the cues, so a JSON-only restore keeps the timings.
        let attachmentIDs = notes.compactMap { $0.audioAttachmentID }
        let audioAttachments: [AudioAttachmentBackup] = attachmentIDs
            .compactMap { audioStore.exportAttachment(for: $0, includeAudioData: false) }
        let audioFiles: [AppBackupArchive.AudioFile] = options.includeAudio
            ? audioAttachments.compactMap { attachment in
                audioStore.audioURL(for: attachment.attachmentID).map {
                    AppBackupArchive.AudioFile(source: $0, name: attachment.attachmentID.uuidString + "." + $0.pathExtension)
                }
            }
            : []
        let extras = AppBackupExtrasStore.collect(
            notes: notes,
            options: options,
            breakdownStore: songBreakdownStore,
            savedKanjiStore: savedKanjiStore
        )
        let payload = AppBackupPayload(
            notes: notes,
            words: wordsStore.words,
            wordLists: wordListsStore.lists,
            history: historyStore.entries,
            reviewStats: reviewStats,
            markedWrong: Array(wordsStore.markedWrong).sorted(),
            learned: Array(wordsStore.learned).sorted(),
            notLearned: Array(wordsStore.notLearned).sorted(),
            mastered: Array(wordsStore.mastered).sorted(),
            lifetimeCorrect: wordsStore.lifetimeCorrect,
            lifetimeAgain: wordsStore.lifetimeAgain,
            audioAttachments: audioAttachments,
            customWords: customWordStore.state,
            extras: extras
        )
        AppLog.debug(
            .backup,
            "export: staged \(notes.count) notes, \(audioFiles.count) audio files, \(extras.stemFiles.count) stems, \(reviewStats.count) review records"
        )

        guard options.includeAudio || options.includeStems else {
            exportDocument = AppBackupDocument(payload: payload)
            exportContentType = .json
            isShowingExporter = true
            return
        }

        isPreparingExport = true
        let stemsDirectory = AppBackupExtrasStore.stemsDirectory()
        let stemFiles = extras.stemFiles
        Task {
            do {
                let json = try AppBackupDocument(payload: payload).encodedPayload()
                let archive = try await Task.detached(priority: .userInitiated) {
                    try AppBackupArchive.build(json: json, audio: audioFiles, stemsDirectory: stemsDirectory, stemFiles: stemFiles)
                }.value
                var document = AppBackupDocument(payload: payload)
                document.archiveURL = archive
                exportDocument = document
                exportContentType = .zip
                isPreparingExport = false
                isShowingExporter = true
            } catch {
                isPreparingExport = false
                AppLog.error(.backup, "export: archive failed — \(error.localizedDescription)")
                showTransferAlert(title: "Export Failed", message: error.localizedDescription)
            }
        }
    }

    // Reports whether the export operation finished or failed.
    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            AppLog.info(.backup, "export: saved to \(url.lastPathComponent)")
            UITestBackupShortcut.rememberExport(at: url)
            showTransferAlert(title: "Export Complete", message: "Your app backup was saved successfully.")
        case .failure(let error):
            AppLog.error(.backup, "export: failed — \(error.localizedDescription)")
            showTransferAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    // Validates the importer selection and loads the selected app-backup file.
    func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else {
                showTransferAlert(title: "Import Failed", message: "No file was selected.")
                return
            }

            let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let document = try AppBackupDocument(contentsOf: fileURL)
                // Reject structurally invalid backups before the destructive
                // replace-all confirmation is ever offered.
                try AppBackupValidator.validate(document.payload)
                AppLog.debug(
                    .backup,
                    "import: \(fileURL.lastPathComponent) validated — \(document.payload.notes.count) notes, \(document.payload.audioAttachments.count) audio attachments"
                )
                pendingImportDocument = document
                isShowingImportConfirmation = true
            } catch {
                AppLog.error(.backup, "import: \(fileURL.lastPathComponent) rejected — \(error.localizedDescription)")
                showTransferAlert(title: "Import Failed", message: error.localizedDescription)
            }
        case .failure(let error):
            AppLog.error(.backup, "import: file selection failed — \(error.localizedDescription)")
            showTransferAlert(title: "Import Failed", message: error.localizedDescription)
        }
    }

    // Applies one validated app-backup snapshot to every persisted store in a single replace-all pass.
    // Audio files are staged first (rolled back on failure); notes are replaced next since disk-backed
    // JSON is the only remaining store that can fail to persist — a failure there aborts before any
    // other store is touched and surfaces an explicit error, instead of proceeding silently.
    func importAppBackup(_ document: AppBackupDocument) {
        let payload = document.payload
        // Validation already rejected duplicate review IDs; uniquingKeysWith is a
        // defense-in-depth guard so a missed case degrades instead of trapping.
        let stats = Dictionary(
            payload.reviewStats.map { ($0.canonicalEntryID, $0.reviewWordStats()) },
            uniquingKeysWith: { current, _ in current }
        )

        let audioStore = NotesAudioStore.shared
        let liveAttachmentIDs = Set(notesStore.notes.compactMap(\.audioAttachmentID))
        var stagedAttachmentIDs: [UUID] = []
        for attachment in payload.audioAttachments {
            do {
                let audioSource = document.assetsDirectory.flatMap { AppBackupArchive.audioFile(for: attachment.attachmentID, in: $0) }
                try audioStore.importAttachment(attachment, audioSource: audioSource)
                stagedAttachmentIDs.append(attachment.attachmentID)
            } catch {
                // Roll back files staged by this import; an ID also referenced by a
                // live note predates the import and must survive the abort.
                rollbackStagedAttachments(stagedAttachmentIDs, excluding: liveAttachmentIDs, using: audioStore)
                AppLog.error(
                    .backup,
                    "import: aborted — audio attachment \(attachment.attachmentID) restore failed, rolled back \(stagedAttachmentIDs.count) staged file(s): \(error.localizedDescription)"
                )
                showTransferAlert(
                    title: "Import Failed",
                    message: "An audio attachment could not be restored, so no data was changed. \(error.localizedDescription)"
                )
                return
            }
        }

        // Notes are the one store here that can genuinely fail to persist — bail before
        // touching any other store instead of silently reporting success over stale notes.
        notesStore.replaceAll(with: payload.notes)
        if let notesError = notesStore.persistenceError {
            rollbackStagedAttachments(stagedAttachmentIDs, excluding: liveAttachmentIDs, using: audioStore)
            AppLog.error(
                .backup,
                "import: aborted — notes persistence failed, rolled back \(stagedAttachmentIDs.count) staged file(s): \(notesError)"
            )
            showTransferAlert(title: "Import Failed", message: "Notes could not be restored, so no data was changed. \(notesError)")
            return
        }

        wordListsStore.replaceAll(with: payload.wordLists)
        wordsStore.replaceAll(with: payload.words)
        historyStore.replaceAll(with: payload.history)
        if let customWords = payload.customWords {
            customWordStore.replaceAll(with: customWords)
        }
        if let extras = payload.extras {
            AppBackupExtrasStore.apply(
                extras,
                stemsSource: document.assetsDirectory.map { AppBackupArchive.stemsDirectory(in: $0) },
                breakdownStore: songBreakdownStore,
                savedKanjiStore: savedKanjiStore
            )
        }
        // Applies the parallel review arrays on top of the just-restored words. For a backup
        // exported after the ReviewStore/WordsStore merge this just reapplies the same data
        // that `payload.words` already carries; for an older backup (where review data lived
        // only in these separate arrays) this is what actually restores it.
        wordsStore.applyLegacyReviewBackup(
            stats: stats,
            markedWrong: Set(payload.markedWrong),
            learned: Set(payload.learned),
            notLearned: Set(payload.notLearned),
            mastered: Set(payload.mastered),
            lifetimeCorrect: payload.lifetimeCorrect,
            lifetimeAgain: payload.lifetimeAgain
        )

        AppLog.info(
            .backup,
            "import: replaced all stores — \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, \(payload.audioAttachments.count) audio attachments"
        )
        var message = "Imported \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, \(payload.history.count) history entries, and \(payload.reviewStats.count) review records."
        if payload.audioAttachments.isEmpty == false {
            let withAudio = payload.audioAttachments.filter { attachment in
                attachment.audioData.isEmpty == false
                    || document.assetsDirectory.flatMap { AppBackupArchive.audioFile(for: attachment.attachmentID, in: $0) } != nil
            }.count
            message += withAudio == 0
                ? " Restored lyric timings for \(payload.audioAttachments.count) audio attachment(s); this backup has no audio files."
                : " Restored \(withAudio) audio file(s)."
        }
        if let extras = payload.extras {
            message += " Also restored \(extras.breakdowns.count) song breakdowns and \(extras.savedKanji.count) saved kanji."
        }

        showTransferAlert(title: "Import Complete", message: message)
    }

    // Deletes every staged attachment that doesn't also belong to a note already on disk before
    // the import started — an id in both sets predates this import and must survive the abort.
    // Shared by the two abort paths in importAppBackup (attachment-restore failure, notes-persist
    // failure), which otherwise repeated this exact loop.
    private func rollbackStagedAttachments(_ stagedAttachmentIDs: [UUID], excluding liveAttachmentIDs: Set<UUID>, using audioStore: NotesAudioStore) {
        for stagedID in stagedAttachmentIDs where liveAttachmentIDs.contains(stagedID) == false {
            audioStore.deleteAttachment(stagedID)
        }
    }
}
