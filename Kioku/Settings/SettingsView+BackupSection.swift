import Foundation

// Backup export/import logic, extracted from SettingsView to keep the parent file under the
// project's 1000-line invariant. All @State / @EnvironmentObject this extension touches are
// declared non-private on SettingsView specifically so this file can reach them — see the "Not
// private" comments at each property's declaration site.
extension SettingsView {
    // Captures the latest full app state before presenting the system export flow.
    func beginAppExport() {
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
                learned: Array(reviewStore.learned).sorted(),
                notLearned: Array(reviewStore.notLearned).sorted(),
                mastered: Array(reviewStore.mastered).sorted(),
                lifetimeCorrect: reviewStore.lifetimeCorrect,
                lifetimeAgain: reviewStore.lifetimeAgain,
                audioAttachments: audioAttachments
            )
        )
        AppLog.debug(.backup, "export: staged \(notes.count) notes, \(audioAttachments.count) audio attachments, \(reviewStats.count) review records")
        isShowingExporter = true
    }

    // Reports whether the export operation finished or failed.
    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            AppLog.info(.backup, "export: saved to \(url.lastPathComponent)")
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
                AppLog.debug(.backup, "import: \(fileURL.lastPathComponent) validated — \(document.payload.notes.count) notes, \(document.payload.audioAttachments.count) audio attachments")
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
                try audioStore.importAttachment(attachment)
                stagedAttachmentIDs.append(attachment.attachmentID)
            } catch {
                // Roll back files staged by this import; an ID also referenced by a
                // live note predates the import and must survive the abort.
                for stagedID in stagedAttachmentIDs where liveAttachmentIDs.contains(stagedID) == false {
                    audioStore.deleteAttachment(stagedID)
                }
                AppLog.error(.backup, "import: aborted — audio attachment \(attachment.attachmentID) restore failed, rolled back \(stagedAttachmentIDs.count) staged file(s): \(error.localizedDescription)")
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
            for stagedID in stagedAttachmentIDs where liveAttachmentIDs.contains(stagedID) == false {
                audioStore.deleteAttachment(stagedID)
            }
            AppLog.error(.backup, "import: aborted — notes persistence failed, rolled back \(stagedAttachmentIDs.count) staged file(s): \(notesError)")
            showTransferAlert(title: "Import Failed", message: "Notes could not be restored, so no data was changed. \(notesError)")
            return
        }

        wordListsStore.replaceAll(with: payload.wordLists)
        wordsStore.replaceAll(with: payload.words)
        historyStore.replaceAll(with: payload.history)
        reviewStore.replaceAll(
            stats: stats,
            markedWrong: Set(payload.markedWrong),
            lifetimeCorrect: payload.lifetimeCorrect,
            lifetimeAgain: payload.lifetimeAgain,
            learned: Set(payload.learned),
            notLearned: Set(payload.notLearned),
            mastered: Set(payload.mastered)
        )

        AppLog.info(.backup, "import: replaced all stores — \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, \(payload.audioAttachments.count) audio attachments")
        var message = "Imported \(payload.notes.count) notes, \(payload.words.count) words, \(payload.wordLists.count) lists, \(payload.history.count) history entries, and \(payload.reviewStats.count) review records."
        if payload.audioAttachments.isEmpty == false {
            message += " Restored \(payload.audioAttachments.count) audio attachment(s)."
        }

        showTransferAlert(title: "Import Complete", message: message)
    }
}
