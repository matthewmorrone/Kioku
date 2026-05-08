import SwiftUI

// Hosts the sense-card UI and the sense/gloss selection toggles for WordDetailView so the main
// view file stays under the per-file line budget.
extension WordDetailView {
    // Toggle the whole sense. Always strips any per-gloss selections of that sense — the two
    // levels are mutually exclusive for one sense.
    func toggleSenseSelection(_ senseID: Int64) {
        var senses = currentSelectedSenseIDs
        var glosses = currentSelectedGlosses
        if let idx = senses.firstIndex(of: senseID) {
            senses.remove(at: idx)
        } else {
            senses.append(senseID)
            glosses.removeAll { $0.senseID == senseID }
        }
        wordsStore.setSelection(id: word.canonicalEntryID, senseIDs: senses, glosses: glosses)
    }

    // Toggle one gloss. If the parent sense is currently whole-selected, narrow down: clear the
    // sense, set just this gloss. If completing this gloss makes every gloss in the sense
    // selected, promote: clear the per-gloss entries for this sense, add the whole sense.
    func toggleGlossSelection(senseID: Int64, glossIndex: Int, totalGlossesInSense: Int) {
        var senses = currentSelectedSenseIDs
        var glosses = currentSelectedGlosses
        let ref = GlossRef(senseID: senseID, glossIndex: glossIndex)

        if senses.contains(senseID) {
            senses.removeAll { $0 == senseID }
            glosses.removeAll { $0.senseID == senseID }
            glosses.append(ref)
        } else if let existingIdx = glosses.firstIndex(of: ref) {
            glosses.remove(at: existingIdx)
        } else {
            glosses.append(ref)
            let pickedForSense = glosses.filter { $0.senseID == senseID }
            if pickedForSense.count == totalGlossesInSense {
                glosses.removeAll { $0.senseID == senseID }
                senses.append(senseID)
            }
        }
        wordsStore.setSelection(id: word.canonicalEntryID, senseIDs: senses, glosses: glosses)
    }

    // Renders one sense card: tappable header strip carrying POS / frequency / misc tags above
    // a stack of bordered gloss sub-cards. Header tap toggles the whole sense; gloss tap toggles
    // that one gloss (with mutual-exclusion handling above).
    @ViewBuilder
    func senseCard(sense: DictionaryEntrySense, isSavedEntry: Bool, isFirstSenseInEntry: Bool, freqLabel: String?, refs: [SenseReference]) -> some View {
        let senseSelected = isSavedEntry && currentSelectedSenseIDs.contains(sense.senseID)
        let selectedGlossIndices: Set<Int> = {
            guard isSavedEntry else { return [] }
            return Set(currentSelectedGlosses.filter { $0.senseID == sense.senseID }.map { $0.glossIndex })
        }()

        VStack(alignment: .leading, spacing: 10) {
            senseHeaderStrip(sense: sense, isSavedEntry: isSavedEntry, isFirstSenseInEntry: isFirstSenseInEntry, freqLabel: freqLabel)
                .contentShape(Rectangle())
                .onTapGesture { if isSavedEntry { toggleSenseSelection(sense.senseID) } }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(sense.glosses.enumerated()), id: \.offset) { gIdx, gloss in
                    let glossSelected = selectedGlossIndices.contains(gIdx)
                    Text(gloss)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    glossSelected ? Color.accentColor : Color.white.opacity(0.06),
                                    lineWidth: glossSelected ? 2 : 0.5
                                )
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSavedEntry {
                                toggleGlossSelection(senseID: sense.senseID, glossIndex: gIdx, totalGlossesInSense: sense.glosses.count)
                            }
                        }
                }
            }

            // Cross-references and antonyms for this sense.
            let xrefs = refs.filter { $0.type == .xref }.map(\.target)
            let ants  = refs.filter { $0.type == .ant  }.map(\.target)
            if xrefs.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("See also:").font(.caption2).foregroundStyle(.tertiary)
                    Text(xrefs.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if ants.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Antonym:").font(.caption2).foregroundStyle(.tertiary)
                    Text(ants.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.tertiarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    senseSelected ? Color.accentColor : Color.white.opacity(0.05),
                    lineWidth: senseSelected ? 2 : 1
                )
        )
    }

    // Header strip: POS first, then frequency (only on first sense — entry-level), then any
    // misc/field/dialect tags (uk, arch, etc.). Renders all sense-level metadata together so
    // misc tags don't sit alone below the gloss list as before.
    @ViewBuilder
    func senseHeaderStrip(sense: DictionaryEntrySense, isSavedEntry: Bool, isFirstSenseInEntry: Bool, freqLabel: String?) -> some View {
        let posLabel: String? = (sense.pos?.isEmpty == false) ? JMdictTagExpander.expandAll(sense.pos ?? "") : nil
        let metaTags: [String] = [sense.misc, sense.field, sense.dialect]
            .compactMap { $0 }
            .filter { $0.isEmpty == false }
            .map { JMdictTagExpander.expandAll($0) }

        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let posLabel {
                Text(posLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if isFirstSenseInEntry, let freqLabel {
                Text(freqLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
            }
            ForEach(metaTags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer(minLength: 0)
        }
    }
}
