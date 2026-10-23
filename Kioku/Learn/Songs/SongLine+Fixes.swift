import Foundation

nonisolated extension SongLine {
    // This line once `fix` is dealt with: the fix leaves its pending list, and an applied typo fix
    // also rewrites the line's own text (and the matching word headwords) so the breakdown still
    // matches the corrected note.
    func resolving(_ fix: SongLineFix, applied: Bool) -> SongLine {
        let remaining = (fixes ?? []).filter { $0 != fix }
        let isTypo = applied && fix.kind == .typo
        // Replaces the first occurrence of the typo, the one the note edit changed.
        func corrected(_ text: String) -> String {
            guard isTypo, let range = text.range(of: fix.originalSurface) else { return text }
            return text.replacingCharacters(in: range, with: fix.replacementSurface)
        }
        return SongLine(
            index: index,
            original: corrected(original),
            romaji: romaji,
            words: words.map { word in
                SongWord(surface: corrected(word.surface), sungRomaji: word.sungRomaji,
                         definition: word.definition, grammarTag: word.grammarTag)
            },
            gist: gist,
            grammarNote: grammarNote,
            reference: reference,
            isVocalization: isVocalization,
            segmentationNote: segmentationNote,
            fixes: remaining.isEmpty ? nil : remaining
        )
    }
}
