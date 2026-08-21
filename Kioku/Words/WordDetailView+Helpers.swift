import SwiftUI

// One upward-arcing curve from a frame's bottom-left to bottom-right corner, peaking at the
// frame's top-center — the sublattice diagram's visual "edge" connecting two lattice nodes.
// Kept at file scope (not nested in the WordDetailView extension below) so it doesn't inherit
// that type's MainActor isolation — Shape.path(in:) is a nonisolated protocol requirement, and
// a nested conformance would need explicit `nonisolated` annotations to satisfy it instead.
nonisolated struct LatticeArcShape: Shape {
    // Draws the quadratic arc from the frame's bottom-left to bottom-right, peaking at top-center.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        return path
    }
}

// Data-loading and presentation helpers for WordDetailView: the live saved-word lookup,
// the async display-data/related-words/conjugation loader, reading inflection, and the
// small reusable row/label view builders. Extracted from WordDetailView so the primary
// file stays under the line-count invariant.
extension WordDetailView {
    // Thin shim kept so call sites inside this view extension stay short and readable;
    // the actual factory lives on SavedWord so KanjiDetailView (and any future caller)
    // can share it without duplicating the surface-picking logic.
    func ephemeralSavedWord(for entry: DictionaryEntry) -> SavedWord {
        SavedWord.ephemeral(for: entry)
    }

    // Chip strip for the WordDetail header when the saved word matches a structured-morpheme
    // derivation (currently only ～がり屋). Each chip stacks the form (body) over its role
    // (caption2, secondary) inside a capsule; FlowLayout lets a 4-chip strip wrap to a
    // second line on narrow phones rather than truncate. The whole strip carries a single
    // VoiceOver label built from the morpheme summary so the screen reader doesn't read each
    // chip's form and role as two separate items.
    @ViewBuilder
    func derivationMorphemeChips(_ morphemes: [DerivationAnalyzer.Morpheme]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(morphemes.enumerated()), id: \.offset) { _, morpheme in
                VStack(spacing: 1) {
                    Text(morpheme.form)
                        .font(.subheadline.weight(.medium))
                    if morpheme.role.isEmpty == false {
                        Text(morpheme.role)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(morphemes.map { $0.role.isEmpty ? $0.form : "\($0.form) \($0.role)" }.joined(separator: ", "))
    }

    // Visual chart for the "Paths" section, sitting above the existing flat text list (not
    // replacing it): one row per candidate segmentation path, in sublatticePaths' existing
    // most-divided-first order (see WordDetailView+Helpers's sort in the .task loader), each
    // segment its own chip. Replaced an earlier shared-edge lattice-arc diagram (candidate paths
    // sharing a segment collapsed into one curved arc, with divergent alternatives fanned into
    // separate lanes) — mathematically that laid out correctly, but for any note with several
    // divergent short segments the result was small, needle-thin arcs that didn't read as arcs at
    // all. One row per path has no such failure mode: every row is a plain horizontal strip
    // regardless of how many paths there are or how much they diverge.
    @ViewBuilder
    var sublatticeDiagramRowsPerPath: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sublatticePaths.enumerated()), id: \.offset) { _, path in
                HStack(spacing: 4) {
                    ForEach(Array(path.enumerated()), id: \.offset) { _, segment in
                        Text(segment)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // Visual lattice diagram for the "Paths" section, sitting above the flat text list (not
    // replacing it). An actual node-and-edge graph: every distinct character-offset boundary any
    // candidate path crosses is one NODE (a dot) sitting on a shared baseline; every distinct
    // (position, text) segment is one EDGE — a curved arc connecting its start and end node,
    // labeled with the segment text. Segments two or more paths agree on collapse into a single
    // shared edge instead of drawing once per path; only where candidates genuinely diverge do the
    // competing arcs get separate lanes (greedy interval packing, sublatticeEdgeLanes), fanning out
    // above the baseline. Edges are ordered by sublatticeUniqueEdgesBiased — ranked by the FEWEST
    // divisions among any path that uses an edge — so an edge exclusive to a more-divided path gets
    // a higher lane than one belonging to a less-divided path, putting "most divisions" visually on
    // top as originally asked for.
    var sublatticeDiagram: some View {
        sublatticeArcDiagram(edges: sublatticeUniqueEdgesBiased(for: sublatticePaths))
    }

    // Shared rendering behind sublatticeDiagram: lays out a given edge list into lanes and draws
    // each as a dome-and-stems arc (sublatticeArc) above the shared baseline nodes.
    @ViewBuilder
    private func sublatticeArcDiagram(edges: [SublatticeEdge]) -> some View {
        let charWidth: CGFloat = 22
        let laneHeight: CGFloat = 22
        let nodeRadius: CGFloat = 3
        let labelHeadroom: CGFloat = 14

        let laneByEdge = sublatticeEdgeLanes(for: edges)
        let laneCount = max((laneByEdge.values.max() ?? 0) + 1, 1)
        let allBoundaries = Set(edges.flatMap { [$0.start, $0.end] }).sorted()
        let totalWidth = CGFloat(allBoundaries.max() ?? 0) * charWidth
        // Arcs live above this y; nodes sit right on it, which is what visually ties every arc's
        // endpoints together into one connected graph instead of floating independent curves.
        let baselineY = CGFloat(laneCount) * laneHeight
        let totalHeight = baselineY + nodeRadius * 2 + labelHeadroom

        ZStack(alignment: .topLeading) {
            ForEach(edges) { edge in
                let lane = laneByEdge[edge] ?? 0
                let laneTotalHeight = CGFloat(lane + 1) * laneHeight
                let arcWidth = max(CGFloat(edge.end - edge.start) * charWidth, 1)
                let tint = lane.isMultiple(of: 2) ? Color.accentColor : Color.secondary
                sublatticeArc(text: edge.text, width: arcWidth, laneTotalHeight: laneTotalHeight, laneHeight: laneHeight, tint: tint)
                    .offset(x: CGFloat(edge.start) * charWidth, y: baselineY - laneTotalHeight)
            }

            // The shared nodes: one dot per boundary position, sitting on the baseline every
            // arc's endpoints land on.
            ForEach(allBoundaries, id: \.self) { boundary in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: nodeRadius * 2, height: nodeRadius * 2)
                    .offset(
                        x: CGFloat(boundary) * charWidth - nodeRadius,
                        y: baselineY - nodeRadius
                    )
            }
        }
        .frame(width: totalWidth, height: totalHeight, alignment: .topLeading)
        .padding(.vertical, 4)
        .accessibilityHidden(true) // The Text rows below already speak each path in full.
    }

    // One edge's visual: a properly-proportioned dome (bowHeight is capped at one laneHeight and
    // scales with the edge's own width, so it never gets taller than it is wide) sitting atop
    // straight stems that bridge the remaining distance down to the shared baseline. A single
    // curve stretched the entire lane depth used to render as a near-vertical spike for narrow
    // edges deep in the stack; decoupling "how much this arc bows" (proportional to its own
    // width, always dome-shaped) from "how far up its lane sits" (the stems) fixes that.
    @ViewBuilder
    private func sublatticeArc(text: String, width: CGFloat, laneTotalHeight: CGFloat, laneHeight: CGFloat, tint: Color) -> some View {
        let bowHeight = min(width * 0.6, laneHeight)
        let stemHeight = max(laneTotalHeight - bowHeight, 0)
        let stemWidth: CGFloat = 1.5
        ZStack(alignment: .top) {
            if stemHeight > 0 {
                Rectangle()
                    .fill(tint.opacity(0.6))
                    .frame(width: stemWidth, height: stemHeight)
                    .offset(x: 0, y: bowHeight)
                Rectangle()
                    .fill(tint.opacity(0.6))
                    .frame(width: stemWidth, height: stemHeight)
                    .offset(x: width - stemWidth, y: bowHeight)
            }
            LatticeArcShape()
                .stroke(tint.opacity(0.6), lineWidth: 1.5)
                .frame(width: width, height: bowHeight)
                .overlay(alignment: .top) {
                    // Sits right at the dome's peak, with an opaque background so it reads as
                    // breaking the line, not crossing it.
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 3)
                        .background(Color(.systemBackground))
                        .fixedSize()
                }
        }
        .frame(width: width, height: laneTotalHeight, alignment: .top)
    }

    // Edge sort backing sublatticeDiagram. Each edge is ranked by the FEWEST divisions among any
    // path that uses it (an edge shared by a 3-division and a 2-division path ranks as 2), and
    // edges are processed lowest-rank-first so greedy packing (sublatticeEdgeLanes) hands
    // least-divided paths' edges the lower lanes and leaves higher lanes for edges exclusive to
    // more-divided paths.
    func sublatticeUniqueEdgesBiased(for paths: [[String]]) -> [SublatticeEdge] {
        var minDivisionsByEdge: [SublatticeEdge: Int] = [:]
        for path in paths {
            var offset = 0
            for segment in path {
                let edge = SublatticeEdge(start: offset, end: offset + segment.count, text: segment)
                minDivisionsByEdge[edge] = min(minDivisionsByEdge[edge] ?? path.count, path.count)
                offset += segment.count
            }
        }
        return minDivisionsByEdge.keys.sorted { lhs, rhs in
            let lhsRank = minDivisionsByEdge[lhs] ?? 0
            let rhsRank = minDivisionsByEdge[rhs] ?? 0
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.text < rhs.text
        }
    }

    // One segment at a specific character-offset span — the lattice diagram's "edge." Hashable
    // by (start, end, text) so two paths that pick the identical segment at the identical
    // position collapse to the same value, which is what lets edges dedupe.
    struct SublatticeEdge: Hashable, Identifiable {
        let start: Int
        let end: Int
        let text: String
        var id: Self { self }
    }

    // Greedy interval-graph lane assignment: edges are placed in the first lane whose last-placed
    // edge ends at or before this edge's start (no horizontal overlap), else a new lane opens.
    // Shared segments (agreed on by every path) need only ever occupy one lane; extra lanes only
    // appear where candidate paths genuinely diverge into overlapping alternative segmentations.
    func sublatticeEdgeLanes(for sortedEdges: [SublatticeEdge]) -> [SublatticeEdge: Int] {
        var laneEnds: [Int] = []
        var laneByEdge: [SublatticeEdge: Int] = [:]
        for edge in sortedEdges {
            if let lane = laneEnds.firstIndex(where: { $0 <= edge.start }) {
                laneByEdge[edge] = lane
                laneEnds[lane] = edge.end
            } else {
                laneByEdge[edge] = laneEnds.count
                laneEnds.append(edge.end)
            }
        }
        return laneByEdge
    }

    // SF Symbol for the header's save/learned toggle: a plain checkmark when learned, a plain
    // question mark when explicitly not-learned, else the save star (filled when saved). Mirrors
    // the row's learnedIcon so the same mark reads identically in the list and the detail header.
    func detailLearnedIcon(state: LearnedState, saved: Bool) -> String {
        switch state {
        case .learned:    return "checkmark"
        case .notLearned: return "questionmark"
        case .unmarked:   return saved ? "star.fill" : "star"
        }
    }

    // Reads the live saved word from the store so the picker reflects toggled state immediately.
    // Falls back to the SavedWord the view was opened with for the brief window before the store
    // publish reaches @EnvironmentObject.
    var currentSavedWord: SavedWord {
        wordsStore.words.first { $0.canonicalEntryID == activeEntryID } ?? word
    }
    var currentSelectedSenseIDs: [Int64] { currentSavedWord.selectedSenseIDs }
    var currentSelectedGlosses: [GlossRef] { currentSavedWord.selectedGlosses }

    // Delegates to the unit-tested WordVariants helper. Surfaces both kanji and
    // kana alternates for kanji-bearing saved surfaces; returns [] for pure-kana
    // surfaces (see WordVariants for the rationale and filter rules).
    func alternateSpellings(entry: DictionaryEntry) -> [String] {
        WordVariants.alternateSpellings(savedSurface: word.surface, entry: entry)
    }

    // Returns true when the entry flags the word as usually written in kana alone.
    func isUsuallyKana(entry: DictionaryEntry) -> Bool {
        entry.senses.contains { ($0.misc ?? "").contains("uk") }
    }

    // Fetches display data for all entries matching the saved surface, placing the saved entry first.
    // This ensures all homophone entries are shown while keeping the saved entry's context primary.
    func loadDisplayData() async {
        guard let dictionaryStore else { return }
        let surface = word.surface
        let savedEntryID = activeEntryID

        let (results, variants) = await Task { @MainActor in
            // Look up all entries matching the surface, choosing mode by script. This is NOT a
            // no-op: the two modes return the same *result set* for a pure-kana surface (kana
            // can't match a kanji column), but they ORDER differently. The demonstrative/particle
            // POS boost in fetchMatchedEntries is gated to `matchKana && !matchKanji`, so only
            // .kanaOnly promotes その (adj-pn "that") above its rare homograph 園 ("garden"). A
            // prior "these are identical, simplify to .kanjiAndKana" edit silently disabled that
            // boost and buried その's primary sense in 3rd place under the archaic garden entry.
            let mode: LookupMode = ScriptClassifier.containsKanji(surface) ? .kanjiAndKana : .kanaOnly
            let entries = (try? dictionaryStore.lookup(surface: surface, mode: mode)) ?? []

            // Build display data for each entry, saved entry first.
            var ordered: [WordDisplayData] = []
            var rest: [WordDisplayData] = []
            for entry in entries {
                if let data = try? dictionaryStore.fetchWordDisplayData(entryID: entry.entryId, surface: surface) {
                    if entry.entryId == savedEntryID {
                        ordered.insert(data, at: 0)
                    } else {
                        rest.append(data)
                    }
                }
            }
            // If saved entry wasn't in the lookup results, fetch it directly.
            if ordered.isEmpty {
                if let data = try? dictionaryStore.fetchWordDisplayData(entryID: savedEntryID, surface: surface) {
                    ordered.append(data)
                }
            }
            var combined = ordered + rest

            // Heteronym readings: gather every reading that shares this word's everyday-kanji spelling
            // (抱く → いだく / だく / うだく), each tied to its own JMdict entry, reusing the Read-tab
            // lookup sheet's gathering (ReadingVariants). The inflected-surface lookup above only
            // resolves one of the homographs, so the siblings would otherwise never be listed or
            // navigable. Siblings not already present are appended; archaic/obscure-only ones are
            // dropped unless the user opted in. Skipped entirely for pure-kana words (no shared
            // spelling — kana homophones are different words, not alternate readings).
            // Gather on the everyday kanji spelling that matches the surface. When the saved surface
            // is itself a kanji form (e.g. 様 for a word saved on the 様 spelling) use it directly —
            // otherwise a word whose surface kanji is a *secondary* spelling of its entry (様 is a
            // rare form of ためし, whose primary kanji is 例) would gather readings of the unrelated
            // primary kanji. For inflected surfaces (抱かれ, not a kanji form) fall back to the
            // entry's first everyday kanji (抱く).
            let savedEntry = combined.first?.entry
            let lemmaSurface: String = {
                guard let savedEntry else { return surface }
                if savedEntry.kanjiForms.contains(where: { $0.text == surface }) { return surface }
                return savedEntry.firstEverydayKanji?.text ?? surface
            }()
            var heteronyms: [ReadingVariants.Variant] = []
            if ScriptClassifier.containsKanji(lemmaSurface) {
                // Keep only readings whose entry writes lemmaSurface as an everyday kanji form; this
                // drops entries where the shared spelling is a rare/secondary form (様 as a rare
                // spelling of ためし) that would pollute the switcher with unrelated words. The saved
                // entry is always kept so the current reading never vanishes from its own switcher.
                heteronyms = ReadingVariants.variants(
                    surface: lemmaSurface,
                    lexicon: lexicon,
                    store: dictionaryStore,
                    segmenter: segmenter,
                    surfaceReadingData: surfaceReadingData
                ).filter { variant in
                    guard let entry = variant.entry else { return false }
                    if entry.entryId == savedEntryID { return true }
                    return entry.kanjiForms.contains {
                        $0.text == lemmaSurface && DictionaryEntry.kanjiFormIsNonEveryday(info: $0.info) == false
                    }
                }
                let includeArchaic = DictionarySettings.includeArchaicReadings
                var presentIDs = Set(combined.map { $0.entry.entryId })
                for variant in heteronyms {
                    guard let sibling = variant.entry, presentIDs.contains(sibling.entryId) == false else { continue }
                    if includeArchaic == false && DefaultSenseSelection.isEntirelyLowPriority(sibling) { continue }
                    if let data = try? dictionaryStore.fetchWordDisplayData(entryID: sibling.entryId, surface: surface) {
                        combined.append(data)
                        presentIDs.insert(sibling.entryId)
                    }
                }
            }
            return (combined, heteronyms)
        }.value

        allDisplayData = results
        readingVariants = variants
        hasAttemptedLoad = true

        guard results.isEmpty == false else { return }
        let store = dictionaryStore

        // Analyze the dictionary base form, not the (possibly inflected) saved surface, so the
        // derivation rules match conjugated saves too (生まれた → 生まれる, 生きてゆいた → 生きてゆく).
        // Use the saved surface when it is itself a base form; otherwise fall back to the entry's
        // primary kanji/kana headword.
        let analysisForm: String = {
            guard let entry = results.first?.entry else { return surface }
            let forms = entry.kanjiForms.map(\.text) + entry.kanaForms.map(\.text)
            if forms.contains(surface) { return surface }
            return entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? surface
        }()

        // Fetch components and sublattice paths via segmenter when available.
        if let segmenter {
            let result = segmenter.longestMatchResult(for: surface)
            // Per-position lemmas of the chosen path, reused for compound-verb derivation
            // detection. edge.lemma is only ever populated by SegmentListView's own display
            // hydration, never by buildLattice itself — it's empty here, so resolve each edge's
            // surface through preferredLemma to get a real dictionary form (食べ → 食べる).
            // preferring: DerivationAnalyzer.auxiliaryVerbs so a tail like 歩いてゆこう's "ゆこう"
            // resolves to the auxiliary ゆく rather than to itself — see preferredLemma(for:preferring:).
            var componentLemmas = result.selectedEdges.map {
                segmenter.preferredLemma(for: $0.surface, preferring: DerivationAnalyzer.auxiliaryVerbs) ?? $0.surface
            }

            // Compound verbs (食べ始める = 食べ-stem + auxiliary 始める) sometimes collapse to a
            // single selected edge via Deinflector's compoundVerbRecoveryForms — correct for the
            // chosen lookup path, but it discards the auxiliary for derivation detection below.
            // The full lattice (not just the winning path) still holds the natural two-token
            // split as its own edges; recover it so DerivationAnalyzer can still name the compound.
            if componentLemmas.count < 2,
               let rawSplit = LatticeEdge.auxiliaryVerbSplit(
                   from: result.latticeEdges,
                   auxiliaries: DerivationAnalyzer.auxiliaryVerbs,
                   lemmaResolver: { segmenter.preferredLemma(for: $0, preferring: DerivationAnalyzer.auxiliaryVerbs) }
               ) {
                componentLemmas = rawSplit.map { segmenter.preferredLemma(for: $0, preferring: DerivationAnalyzer.auxiliaryVerbs) ?? $0 }
            }

            // Derivation description for the header — names the base word + affix for derived
            // forms (弱さ, お酒, 生まれる, 生きてゆく). The resolver hands the analyzer the JMdict POS
            // tags of any candidate lemma so it can confirm and label the base. nil → plain POS line.
            let detected = await Task { @MainActor in
                DerivationAnalyzer.analyze(
                    surface: analysisForm, components: componentLemmas,
                    baseResolver: { lemma in
                        let entries = (try? store.lookup(surface: lemma, mode: .kanjiAndKana)) ?? []
                        return entries.flatMap { $0.senses.compactMap(\.pos) }
                            .flatMap { $0.components(separatedBy: ",") }
                    },
                    glossResolver: { lemma in
                        let entries = (try? store.lookup(surface: lemma, mode: .kanjiAndKana)) ?? []
                        return entries.first?.senses.first?.glosses.first
                    }
                )
            }.value
            derivation = detected

            // Components breakdown. Primary path is data-driven affix decomposition (科学 + 的,
            // 子供 + たち), gated on JMdict bound-morpheme tags plus a real base word — see
            // affixBreakdown. Only when that finds nothing do we fall back to the (possibly
            // sublattice-recovered) compound components, and even then only when DerivationAnalyzer
            // recognized a real derivation (compound verb 食べ始める). An atomic word (その) matches
            // neither, so its Components section stays empty instead of showing a spurious kana split.
            let affixBreakdown = await Task { @MainActor in store.affixBreakdown(for: analysisForm) }.value
            if let affixBreakdown {
                wordComponents = affixBreakdown.map { (surface: $0.surface, gloss: $0.gloss) }
            } else if detected != nil, componentLemmas.count > 1 {
                let components = await Task { @MainActor in
                    componentLemmas.compactMap { lemma -> (String, String?)? in
                        let entries = try? store.lookup(surface: lemma, mode: .kanjiAndKana)
                        let gloss = entries?.first?.senses.first?.glosses.first
                        return (lemma, gloss)
                    }
                }.value
                wordComponents = components
            }

            // Use pre-computed paths from the lookup sheet; fall back to computing from the segmenter.
            let paths = initialSublatticePaths.isEmpty
                ? LatticeEdge.validPaths(from: result.latticeEdges)
                : initialSublatticePaths
            // Most-divided path (most segments) first, coarsest (fewest segments) last — the
            // "Paths" list below the diagram reads finest-grained-first.
            sublatticePaths = paths.sorted { $0.count > $1.count }
        }

        // Fetch kanji breakdown for each unique kanji character in the surface.
        let uniqueKanji = word.surface
            .map(String.init)
            .filter { ScriptClassifier.containsKanji($0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let infos = await Task { @MainActor in
            uniqueKanji.compactMap { try? store.fetchKanjiInfo(for: $0) }
        }.value
        kanjiInfos = infos

        // Related words — other entries sharing the headword's primary (first) kanji, ranked
        // by frequency. Approximates the reference's kanji-family "Related Words" list.
        // Excludes the saved entry and any entry whose kanji form is exactly the saved surface.
        if let primaryKanji = uniqueKanji.first {
            let savedID = activeEntryID
            let savedSurface = word.surface
            let related = await Task { @MainActor in
                (try? store.searchEntriesContainingKanji(literal: primaryKanji, limit: 40)) ?? []
            }.value
            relatedEntries = Array(
                related
                    .filter { $0.entryId != savedID }
                    .filter { entry in entry.kanjiForms.contains { $0.text == savedSurface } == false }
                    .prefix(30)
            )
        }

        // Fetch cross-references, antonyms, and loanword origins for the saved entry.
        let savedID = activeEntryID
        let sources = await Task { @MainActor in
            (try? store.fetchLoanwordSources(entryID: savedID)) ?? []
        }.value
        loanwordSources = sources

        let refs = await Task { @MainActor in
            (try? store.fetchSenseReferences(entryID: savedID)) ?? []
        }.value
        senseReferences = refs

        // Synonyms — resolve the saved entry's JMdict cross-references (xref "see also" links)
        // to full dictionary entries so they can be shown as their own browsable section. The
        // target may be a bare word or "word・reading・senseNum"; the leading element before the
        // first middle dot is the headword to look up. Entries already shown among the kanji-family
        // related words (and the saved entry itself) are skipped so nothing appears twice.
        let xrefHeads = refs
            .filter { $0.type == .xref }
            .map { String($0.target.split(separator: "・").first ?? "") }
            .filter { $0.isEmpty == false }
        if xrefHeads.isEmpty {
            synonymEntries = []
        } else {
            let excluded = Set(relatedEntries.map(\.entryId)).union([savedID])
            synonymEntries = await Task { @MainActor in
                var seen = excluded
                var resolved: [DictionaryEntry] = []
                for head in xrefHeads {
                    let matches = (try? store.lookup(surface: head, mode: .kanjiAndKana)) ?? []
                    guard let first = matches.first, seen.insert(first.entryId).inserted else { continue }
                    resolved.append(first)
                    if resolved.count >= 12 { break }
                }
                return resolved
            }.value
        }

    }

    // Maps ISO 639-2/B language codes to display names for common loanword source languages.
    func languageName(for code: String) -> String {
        let map: [String: String] = [
            "eng": "English", "fre": "French", "ger": "German",
            "por": "Portuguese", "dut": "Dutch", "ita": "Italian",
            "spa": "Spanish", "rus": "Russian", "chi": "Chinese",
            "kor": "Korean", "san": "Sanskrit", "ara": "Arabic",
        ]
        return map[code] ?? code.uppercased()
    }

    // Derives the inflected reading for the surface from the entry's base forms.
    // When the surface is an inflected form (e.g. 流れた) and the entry stores the base form
    // (流れる / ながれる), the base-form reading can't project onto the inflected surface because
    // the okurigana differ (た vs る). This function finds the common prefix between the base
    // kanji form and the surface, then replaces the base suffix in the reading with the surface's suffix.
    // Returns the base reading unchanged when prefix matching fails or the entry is nil.
    func inflectedReading(surface: String, entry: DictionaryEntry?) -> String? {
        guard let entry, let baseReading = entry.kanaForms.first?.text else { return nil }
        return projectedReading(surface: surface, baseReading: baseReading, kanjiForms: entry.kanjiForms, kanaForms: entry.kanaForms)
    }

    // Projects an explicit base reading onto a (possibly inflected) surface using the given forms —
    // the shared core of inflectedReading. The reading switcher calls this directly with a chosen
    // homograph's base reading so the furigana follows the active reading (いだく→いだかれ, だく→だかれ).
    // Returns the base reading unchanged when the surface is itself a base form or no prefix aligns.
    func projectedReading(surface: String, baseReading: String, kanjiForms: [KanjiForm], kanaForms: [KanaForm]) -> String? {
        // If the surface matches a kanji or kana form exactly, no inflection adjustment needed.
        let isBaseForm = kanjiForms.contains { $0.text == surface } || kanaForms.contains { $0.text == surface }
        if isBaseForm { return baseReading }

        // Try each kanji form to find one that shares a prefix with the surface.
        for kanjiForm in kanjiForms {
            let base = Array(kanjiForm.text)
            let surf = Array(surface)
            let prefixLen = zip(base, surf).prefix(while: { $0 == $1 }).count
            guard prefixLen > 0, prefixLen < base.count, prefixLen < surf.count else { continue }

            let baseSuffix = String(base[prefixLen...])
            let surfaceSuffix = String(surf[prefixLen...])

            // The reading should end with the base form's kana suffix.
            if baseReading.hasSuffix(baseSuffix) {
                return String(baseReading.dropLast(baseSuffix.count)) + surfaceSuffix
            }
        }

        // Fallback: return the base reading and let the header do its best.
        return baseReading
    }

    // Renders a small pill-shaped metadata chip used across multiple sections.
    @ViewBuilder
    func metadataLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }

    // One related-word row: an optional structural-relationship badge, the POS label, the
    // surface + reading, and the leading glosses — the same at-a-glance information the
    // reference shows for each related entry. `relationLabel` is non-nil for the structural
    // entries ordered first in the Related Words list, where it names the trans/intrans pair
    // or same-stem form.
    @ViewBuilder
    func relatedWordRow(_ entry: DictionaryEntry, relationLabel: String? = nil) -> some View {
        let surface = entry.firstEverydayKanji?.text ?? entry.kanjiForms.first?.text ?? entry.kanaForms.first?.text ?? ""
        let reading = entry.kanaForms.first?.text
        let firstSense = entry.senses.first
        let posLabel: String? = {
            guard let pos = firstSense?.pos, pos.isEmpty == false else { return nil }
            return pos.components(separatedBy: ",")
                .filter { $0.isEmpty == false }
                .map { Self.titleCased(JMdictTagExpander.expand($0)) }
                .joined(separator: " · ")
        }()
        let glossText = (firstSense?.glosses ?? []).prefix(3).joined(separator: ", ")

        VStack(alignment: .leading, spacing: 2) {
            if let relationLabel {
                Text(relationLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            if let posLabel {
                Text(posLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(surface)
                    .font(.body.weight(.medium))
                if let reading, reading != surface {
                    Text(reading)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // Chevron signals the row is tappable (call sites wrap in a Button that opens
                // a nested WordDetailView for the related entry). Tertiary tone matches the
                // kanji-row chevron in kanjiRowContent above.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if glossText.isEmpty == false {
                Text(glossText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        // Make the full row hit-testable, not just the rendered text — without this, taps in
        // the empty area between the surface and the chevron miss the Button.
        .contentShape(Rectangle())
    }

    // Compact tappable row content for one kanji character — extracted so the Kanji section
    // can wrap it in a Button without duplicating the layout.
    @ViewBuilder
    func kanjiRowContent(_ info: KanjiInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Center the large glyph against the meanings + metadata block (the first two
            // rows) rather than baseline-aligning it to the meanings row alone.
            HStack(alignment: .center, spacing: 10) {
                Text(info.literal)
                    .font(.system(size: 28, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.meanings.prefix(3).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 8) {
                        if let grade = info.grade {
                            metadataLabel(grade == 8 ? "Secondary" : "Grade \(grade)")
                        }
                        if let jlpt = info.jlptLevel {
                            metadataLabel("JLPT N\(jlpt)")
                        }
                        if let strokes = info.strokeCount {
                            metadataLabel("\(strokes) strokes")
                        }
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if info.onReadings.isEmpty == false {
                HStack(spacing: 4) {
                    Text("ON")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    // Display-time fold to hiragana (KANJIDIC2 stores on'yomi as katakana).
                    // Matches the KanjiDetailView "On'yomi" section; source data unchanged.
                    Text(info.onReadings
                        .map(KanaNormalizer.katakanaToHiragana)
                        .joined(separator: "・"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if info.kunReadings.isEmpty == false {
                HStack(spacing: 4) {
                    Text("KUN")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(info.kunReadings.joined(separator: "・"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
