import SwiftUI

// The "what is this built from" row at the top of the Definition section: 大人になる shown as
// 大人 + に + なる, each content word tappable through to its own entry.
//
// The pieces are read from the dictionary rather than computed here — see
// DictionaryStore.fetchDecomposition and Resources/generate_db.py's import_entry_decomposition.
// The sublattice "Paths" diagram answers a different question: it shows every segmentation the
// lattice considers valid, including the wrong ones (おと + なに + なる), because its subject is
// the ambiguity itself. This row shows the single analysis, which is what a learner reads.
extension WordDetailView {
    // One line of chips with + between them, wrapping when the expression is long.
    @ViewBuilder
    var decompositionRow: some View {
        // Layout-only container: chips flow within the row's width rather than forcing a
        // horizontal scroll on a long expression like からには or 目から鱗が落ちる.
        FlowLayout(spacing: 6) {
            ForEach(Array(entryDecomposition.enumerated()), id: \.element.id) { index, piece in
                if index > 0 {
                    Text("+")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                decompositionChip(piece)
            }
        }
        .padding(.vertical, 6)
    }

    // One piece. Particles and auxiliaries render flat: they resolve to real entries, so leaving
    // them tappable would invite a learner to open に and find eleven senses of a case marker.
    @ViewBuilder
    private func decompositionChip(_ piece: EntryDecompositionPiece) -> some View {
        if piece.isFunctional {
            Text(piece.piece)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        } else {
            Button {
                openDecompositionPiece(piece)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(piece.piece)
                        .font(.subheadline.weight(.medium))
                    // The dictionary form, when the piece is written in an inflected shape —
                    // 食べ is what the expression contains, 食べる is what the tap opens, and
                    // showing only the former makes the destination look like a mistake.
                    if let lemma = piece.lemma {
                        Text(lemma)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // Opens a tapped piece the same way a related-word or lattice-node tap does: looked up by its
    // dictionary form, recorded to history, presented in the nested WordDetailView sheet. Silently
    // does nothing when the piece has no entry of its own.
    private func openDecompositionPiece(_ piece: EntryDecompositionPiece) {
        guard let dictionaryStore else { return }
        let surface = piece.lookupSurface
        let mode: LookupMode = ScriptClassifier.containsKanji(surface) ? .kanjiAndKana : .kanaOnly
        guard let entry = (try? dictionaryStore.lookup(surface: surface, mode: mode))?.first else { return }
        historyStore.record(canonicalEntryID: entry.entryId, surface: entry.primarySearchSurface)
        presentedRelatedSavedWord = ephemeralSavedWord(for: entry)
    }
}
