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
    // File extensions accepted as Praat TextGrid companions for karaoke checkpoint data.
    // Comparison happens after lowercasing the file extension so `.TextGrid` and `.textgrid` both match.
    static let textGridExtensions: Set<String> = ["textgrid"]

    // Returns the input URLs grouped by basename into plan items, preserving the order
    // the user picked them. URLs with unsupported extensions are skipped so the planner
    // never produces an item that the runner cannot act on.
    //
    // `existingAudioBaseNamesByNoteID` lets the matcher recognize an existing note by its stored
    // audio filename basename when the note's title is something else (single-import flow titles
    // notes with the first cue line, not the song filename). Pass an empty map to skip that step.
    static func plan(
        urls: [URL],
        existingNotes: [Note],
        existingAudioBaseNamesByNoteID: [UUID: String] = [:]
    ) -> [BulkImportPlanItem] {
        var itemsByKey: [String: BulkImportPlanItem] = [:]
        var orderedKeys: [String] = []

        for url in urls {
            let baseName = url.deletingPathExtension().lastPathComponent
            let key = baseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ext = url.pathExtension.lowercased()

            guard textExtensions.contains(ext)
                    || subtitleExtensions.contains(ext)
                    || audioExtensions.contains(ext)
                    || textGridExtensions.contains(ext) else {
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
            } else if textGridExtensions.contains(ext) {
                itemsByKey[key]?.textGridURL = url
            }
        }

        return orderedKeys.compactMap { key -> BulkImportPlanItem? in
            guard var item = itemsByKey[key] else { return nil }
            // Match to an existing note when the item carries audio OR is a TextGrid-only companion:
            // a user dropping just `.TextGrid` files for songs they previously imported expects the
            // karaoke data to attach to those notes, not be skipped.
            let isTextGridOnly = item.textGridURL != nil
                && item.audioURL == nil
                && item.subtitleURL == nil
                && item.textURL == nil
            if item.audioURL != nil || isTextGridOnly {
                item.matchedExistingNoteID = matchedNoteID(
                    forBaseName: item.baseName,
                    in: existingNotes,
                    audioBaseNamesByNoteID: existingAudioBaseNamesByNoteID
                )
            }
            return item
        }
    }

    // Returns true when running this item requires Whisper transcription, so the sheet can
    // require model selection before allowing import to start.
    static func requiresTranscription(_ item: BulkImportPlanItem) -> Bool {
        // A .TextGrid alongside the audio supplies line cues without Whisper, so the
        // sheet should not gate import on model selection in that case. The runner's
        // `process` path mirrors this — TextGrid-derived cues are tried before the
        // Whisper transcription branch.
        item.audioURL != nil
            && item.textURL == nil
            && item.subtitleURL == nil
            && item.textGridURL == nil
            && item.matchedExistingNoteID == nil
    }

    // Describes the action the runner will take for one item; used for plan-row labels.
    static func actionDescription(_ item: BulkImportPlanItem) -> String {
        let hasTextGrid = item.textGridURL != nil
        let karaokeSuffix = hasTextGrid ? " with karaoke timings" : ""

        if item.matchedExistingNoteID != nil {
            if item.audioURL == nil && item.subtitleURL == nil && item.textURL == nil && hasTextGrid {
                return "Attach karaoke timings to matching note"
            }
            if item.subtitleURL != nil {
                return "Attach audio and subtitle to matching note" + karaokeSuffix
            }
            return "Attach audio to matching note" + karaokeSuffix
        }

        switch (item.textURL != nil, item.subtitleURL != nil, item.audioURL != nil) {
        case (true, true, true): return "New note from text with audio and subtitle" + karaokeSuffix
        case (true, false, true): return "New note from text with audio" + karaokeSuffix
        case (false, true, true): return "New note from subtitle with audio" + karaokeSuffix
        case (true, true, false): return "New note from text with subtitle" + karaokeSuffix
        case (true, false, false): return "New note from text" + karaokeSuffix
        case (false, true, false): return "New note from subtitle" + karaokeSuffix
        case (false, false, true): return "New note from transcribed audio" + karaokeSuffix
        case (false, false, false):
            return hasTextGrid ? "New note from TextGrid" : "Skipped — no recognized files"
        }
    }

    // Locates an existing note whose trimmed title equals the supplied basename (case-insensitive).
    // Falls back to matching the basename against any provided audio-file basename so notes whose
    // titles differ from their audio filename (the single-import path titles by first cue line)
    // still attach correctly. Used for audio files and for TextGrid-only items.
    private static func matchedNoteID(
        forBaseName baseName: String,
        in notes: [Note],
        audioBaseNamesByNoteID: [UUID: String]
    ) -> UUID? {
        let normalized = baseName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return nil }
        if let titleMatch = notes.first(where: { note in
            note.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }) {
            return titleMatch.id
        }
        for note in notes {
            guard let audioBase = audioBaseNamesByNoteID[note.id] else { continue }
            if audioBase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized {
                return note.id
            }
        }
        return nil
    }
}
