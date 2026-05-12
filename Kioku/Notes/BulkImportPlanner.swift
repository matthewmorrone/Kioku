import Foundation

// Groups a flat picker selection into per-basename plan items so the bulk runner can
// pair txt / srt / audio files that share a common stem (e.g. `lesson1.txt` + `lesson1.srt`).
// Also detects audio files whose basename matches an existing note title so the runner
// attaches the audio instead of generating a duplicate note.
enum BulkImportPlanner {
    // File extensions accepted as plain-text note bodies.
    static let textExtensions: Set<String> = ["txt"]
    // File extensions accepted as subtitle inputs; only SRT is parsed end-to-end.
    static let subtitleExtensions: Set<String> = ["srt"]
    // File extensions accepted as audio inputs. `mp3`/`wav` are required by the feature
    // spec; the additional types here are routinely produced by audio recording apps and
    // are readable via AVAssetReader.
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "caf", "aiff"]

    // Returns the input URLs grouped by basename into plan items, preserving the order
    // the user picked them. URLs with unsupported extensions are skipped so the planner
    // never produces an item that the runner cannot act on.
    static func plan(urls: [URL], existingNotes: [Note]) -> [BulkImportPlanItem] {
        var itemsByKey: [String: BulkImportPlanItem] = [:]
        var orderedKeys: [String] = []

        for url in urls {
            let baseName = url.deletingPathExtension().lastPathComponent
            let key = baseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ext = url.pathExtension.lowercased()

            guard textExtensions.contains(ext)
                    || subtitleExtensions.contains(ext)
                    || audioExtensions.contains(ext) else {
                continue
            }

            if itemsByKey[key] == nil {
                itemsByKey[key] = BulkImportPlanItem(id: key, baseName: baseName)
                orderedKeys.append(key)
            }

            if textExtensions.contains(ext) {
                itemsByKey[key]?.textURL = url
            } else if subtitleExtensions.contains(ext) {
                itemsByKey[key]?.subtitleURL = url
            } else if audioExtensions.contains(ext) {
                itemsByKey[key]?.audioURL = url
            }
        }

        return orderedKeys.compactMap { key -> BulkImportPlanItem? in
            guard var item = itemsByKey[key] else { return nil }
            if item.audioURL != nil {
                item.matchedExistingNoteID = matchedNoteID(forBaseName: item.baseName, in: existingNotes)
            }
            return item
        }
    }

    // Returns true when running this item requires Whisper transcription, so the sheet can
    // require model selection before allowing import to start.
    static func requiresTranscription(_ item: BulkImportPlanItem) -> Bool {
        item.audioURL != nil
            && item.textURL == nil
            && item.subtitleURL == nil
            && item.matchedExistingNoteID == nil
    }

    // Describes the action the runner will take for one item; used for plan-row labels.
    static func actionDescription(_ item: BulkImportPlanItem) -> String {
        if item.matchedExistingNoteID != nil {
            if item.subtitleURL != nil {
                return "Attach audio and subtitle to matching note"
            }
            return "Attach audio to matching note"
        }

        switch (item.textURL != nil, item.subtitleURL != nil, item.audioURL != nil) {
        case (true, true, true): return "New note from text with audio and subtitle"
        case (true, false, true): return "New note from text with audio"
        case (false, true, true): return "New note from subtitle with audio"
        case (true, true, false): return "New note from text with subtitle"
        case (true, false, false): return "New note from text"
        case (false, true, false): return "New note from subtitle"
        case (false, false, true): return "New note from transcribed audio"
        case (false, false, false): return "Skipped — no recognized files"
        }
    }

    // Locates an existing note whose trimmed title equals the supplied basename (case-insensitive).
    // Used only for audio files so unrelated txt/srt imports always create new notes.
    private static func matchedNoteID(forBaseName baseName: String, in notes: [Note]) -> UUID? {
        let normalized = baseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return nil }
        return notes.first(where: { note in
            note.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        })?.id
    }
}
