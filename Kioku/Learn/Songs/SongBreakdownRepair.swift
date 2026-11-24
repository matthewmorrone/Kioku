import Foundation

// A breakdown matched against the note's current lyrics: the lines that still read the same
// (renumbered to their place in the current lyrics) and the numbers of those that need writing.
nonisolated struct SongBreakdownRepairPlan: Sendable {
    let reused: [SongLine]
    let changedIndices: [Int]
    // The current lyrics' lines by number (1-based), for telling the model what to write.
    let lyricLines: [String]
}

// Brings a stale breakdown up to date without regenerating it whole: lines whose text is unchanged
// keep their words and meanings, and only new or edited lines are sent to the model, which reads
// the whole song for context but writes just those. Lines are numbered the way the prompt numbers
// them (the Nth non-blank lyric line is line N), so an inserted or deleted line shifts the numbers
// of the lines after it; repeats ("= line N") are renumbered with them.
enum SongBreakdownRepair {
    // Matches `breakdown`'s lines to `noteText`'s, in order, by their text. A matched line whose
    // repeat reference points at a line that is no longer matched is not reused, since its content
    // came from that line.
    static func plan(for breakdown: SongBreakdown, noteText: String) -> SongBreakdownRepairPlan {
        let lyricLines = LyricLineBreaks.normalized(noteText)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        let oldLines = breakdown.lines.sorted { $0.index < $1.index }
        // Old line number → new line number, found by walking both in order.
        var oldToNew: [Int: Int] = [:]
        var cursor = 0
        for (offset, text) in lyricLines.enumerated() {
            guard let found = oldLines[cursor...].firstIndex(where: { $0.original.trimmingCharacters(in: .whitespaces) == text }) else { continue }
            oldToNew[oldLines[found].index] = offset + 1
            cursor = found + 1
        }
        // Dropping a line can orphan a repeat that points at it, so this runs until nothing changes.
        var changed = true
        while changed {
            changed = false
            for line in oldLines {
                guard oldToNew[line.index] != nil, let reference = line.reference, oldToNew[reference.targetLineIndex] == nil else { continue }
                oldToNew.removeValue(forKey: line.index)
                changed = true
            }
        }
        let reused = oldLines.compactMap { line -> SongLine? in
            guard let newIndex = oldToNew[line.index] else { return nil }
            return SongLine(
                index: newIndex,
                original: line.original,
                romaji: line.romaji,
                words: line.words,
                gist: line.gist,
                grammarNote: line.grammarNote,
                reference: line.reference.flatMap { remapped($0, through: oldToNew) },
                isVocalization: line.isVocalization,
                segmentationNote: line.segmentationNote,
                fixes: line.fixes
            )
        }
        let matched = Set(reused.map(\.index))
        let changedIndices = (1 ... max(1, lyricLines.count)).filter { $0 <= lyricLines.count && matched.contains($0) == false }
        return SongBreakdownRepairPlan(reused: reused, changedIndices: changedIndices, lyricLines: lyricLines)
    }

    // The instruction added to the request so the model writes only the lines that need it.
    static func instruction(for plan: SongBreakdownRepairPlan) -> String {
        let listed = plan.changedIndices.map { "Line \($0): \(plan.lyricLines[$0 - 1])" }.joined(separator: "\n")
        return """
            Most of this song's breakdown already exists. Write the breakdown only for these lines, keeping the line numbers shown, and write nothing for any other line. Read the rest of the lyrics for context only.

            \(listed)
            """
    }

    // The repaired breakdown: the reused lines plus the model's lines for the changed numbers, in
    // line order. A changed line the model didn't write is left out (it shows its dictionary meanings).
    static func merge(plan: SongBreakdownRepairPlan, generated: SongBreakdown) -> SongBreakdown {
        var lines = plan.reused
        var taken = Set<Int>()
        for line in generated.lines where plan.changedIndices.contains(line.index) && taken.insert(line.index).inserted {
            lines.append(line)
        }
        return SongBreakdown(
            noteID: generated.noteID,
            sourceTextHash: generated.sourceTextHash,
            generatedAt: Date(),
            provider: generated.provider,
            lines: lines.sorted { $0.index < $1.index },
            schemaVersion: generated.schemaVersion
        )
    }

    // `reference` pointing at the new number of the line it points at.
    private static func remapped(_ reference: LineReference, through oldToNew: [Int: Int]) -> LineReference? {
        guard let target = oldToNew[reference.targetLineIndex] else { return nil }
        switch reference {
        case .sameAsLine: return .sameAsLine(target)
        case .parallelTo(line: _, substitution: let substitution): return .parallelTo(line: target, substitution: substitution)
        }
    }
}
