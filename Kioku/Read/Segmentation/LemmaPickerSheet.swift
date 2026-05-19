import SwiftUI

// Sheet presented when the user explicitly wants to override the segmenter's
// automatic lemma pick — e.g. for a surface like なった where the segmenter
// picked なる but the user actually meant なう (or vice versa).
//
// The sheet receives the surface string and a list of candidate lemmas (best
// first, matching `Segmenter.lemmaCandidates(for:)`) and looks each one up
// in the dictionary to show the first sense gloss as a disambiguator. The
// `onChoose` callback fires with the picked lemma and its resolved canonical
// entry id; the caller is responsible for turning that into a save action.
//
// When `candidates` has fewer than 2 entries the picker has nothing to
// disambiguate — the caller should skip presenting this sheet and just save
// directly. The view does render with one entry to avoid crashing if it's
// presented anyway, but the UX is degenerate.
struct LemmaPickerSheet: View {
    let surface: String
    let candidates: [String]
    let dictionaryStore: DictionaryStore?
    let onChoose: (_ lemma: String, _ canonicalEntryID: Int64) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Resolved dictionary metadata per candidate, populated on appear. Keys are
    // candidate lemma strings; values are (canonicalEntryID, glossPreview).
    @State private var resolvedByLemma: [String: ResolvedCandidate] = [:]

    private struct ResolvedCandidate {
        let canonicalEntryID: Int64
        let glossPreview: String
        let zipf: Double?
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates, id: \.self) { lemma in
                        candidateRow(lemma: lemma)
                    }
                } header: {
                    Text("Surface: \(surface)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                } footer: {
                    // Footer explains the auto-pick convention so the user
                    // knows that "first row" was what the segmenter would
                    // have chosen on its own.
                    Text("The first entry is what the segmenter would have picked automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Choose Lemma")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .task {
            await resolveCandidates()
        }
    }

    // Renders one candidate row with lemma, optional Zipf badge, and gloss.
    @ViewBuilder
    private func candidateRow(lemma: String) -> some View {
        Button {
            // Resolved data is loaded async — if a user taps before resolution
            // completes, fall back to a placeholder canonical id of 0 which
            // the caller can detect and refuse. In practice the user will see
            // the rows briefly empty before taps land, so this is rare.
            let resolved = resolvedByLemma[lemma]
            if let resolved {
                onChoose(lemma, resolved.canonicalEntryID)
            }
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lemma)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let zipf = resolvedByLemma[lemma]?.zipf {
                        Text(zipfBadge(zipf))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let preview = resolvedByLemma[lemma]?.glossPreview, preview.isEmpty == false {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(resolvedByLemma[lemma] == nil)
    }

    // Human-readable frequency label from the Zipf scale. Zipf is a log-base-10
    // measure of word frequency per billion words — anything above ~6 is
    // extremely common, 4–5 is common in everyday speech, 3–4 is uncommon,
    // and ≤3 is rare. Showing this helps the user weigh competing candidates.
    private func zipfBadge(_ zipf: Double) -> String {
        switch zipf {
        case 6.0...: return "very common"
        case 5.0..<6.0: return "common"
        case 4.0..<5.0: return "moderate"
        case 3.0..<4.0: return "uncommon"
        default: return "rare"
        }
    }

    // Resolves each candidate's canonical entry id + first-sense gloss via the
    // dictionary. Runs once on appear so the rows can render with metadata
    // without blocking the sheet presentation. Failed lookups stay nil; rows
    // for unresolved candidates are visible but disabled (the user can't tap
    // them, preventing a save with an unknown canonical id).
    private func resolveCandidates() async {
        guard let store = dictionaryStore else { return }
        var resolved: [String: ResolvedCandidate] = [:]
        for lemma in candidates {
            // `lookup(surface:mode:)` can return multiple entries for the
            // same string (e.g. なる has several JMdict rows — auxiliary,
            // 為る verb, archaic). Pick the highest-Zipf entry as "the
            // canonical sense" so the gloss preview shows the common
            // meaning ("to become") rather than whichever row the SQL
            // returned first.
            guard let entries = try? store.lookup(surface: lemma, mode: .kanjiAndKana),
                  entries.isEmpty == false else {
                continue
            }
            let bestEntry = entries.max { lhs, rhs in
                (lhs.wordfreqZipf ?? 0) < (rhs.wordfreqZipf ?? 0)
            } ?? entries[0]
            // `glosses` is already `[String]` — no `.text` accessor.
            let glossPreview = bestEntry.senses.first?.glosses.first ?? ""
            resolved[lemma] = ResolvedCandidate(
                canonicalEntryID: bestEntry.entryId,
                glossPreview: glossPreview,
                zipf: bestEntry.wordfreqZipf
            )
        }
        // resolveCandidates is already running on MainActor via SwiftUI's
        // `.task`, but the explicit hop keeps the intent clear if this is
        // ever refactored to a background actor.
        await MainActor.run {
            resolvedByLemma = resolved
        }
    }
}
