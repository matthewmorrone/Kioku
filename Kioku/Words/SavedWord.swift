import Foundation

// Points to a single gloss within a sense — used when the user wants a flashcard meaning to be
// one specific synonym rather than the sense's first-gloss-as-representative.
nonisolated struct GlossRef: Codable, Hashable {
    let senseID: Int64
    let glossIndex: Int
}

// The per-word "have I learned this?" mark, shown on the star: a checkmark for learned, a
// question mark for not-learned, and the plain star when the user hasn't said either way.
// The two marks are mutually exclusive — setting one clears the other. Lives on SavedWord itself
// (not a separate store) — see WordsStore's "MARK: - Review" section for why.
nonisolated enum LearnedState: String, Codable, Hashable {
    case unmarked
    case learned
    case notLearned
}

// Represents one saved word that can belong to multiple note-linked lists and user-created word lists.
// `nonisolated` so import pipelines (CSV, bulk) can construct it from detached tasks.
nonisolated struct SavedWord: Codable, Hashable, Identifiable {
    static let currentSchemaVersion = 1

    let canonicalEntryID: Int64
    // Stable JMdict sequence id for this entry — the rebuild-safe anchor. `entries.id`
    // (canonicalEntryID) is a build-order autoincrement that shifts when the dictionary is
    // regenerated; ent_seq does not. Optional because cards saved before this field existed
    // decode as nil and get it backfilled on first load after the dictionary is ready. Once set,
    // canonicalEntryID is re-resolved from this on every load, so a rebuild can't silently
    // re-point the card. See reconcilingStableKey(...).
    let entSeq: Int64?
    let surface: String
    // Provenance: which notes this word was saved from. Mutable so a word can be detached
    // from a single note ("Remove from <note>") without rebuilding the whole record.
    var sourceNoteIDs: [UUID]
    // True once this card has ever sat with zero note attribution — either created that way
    // (Words tab / dictionary lookup, no note involved) or detached down to empty by
    // WordsStore.removeNoteMembership / detachNoteReferences. Never reset back to false once
    // set, even after a later note attribution is added. Vocab mode's "undo the last note
    // attribution" action reads this to decide whether reaching zero attribution again should
    // leave the card as a standalone orphan (it's been there before) or fully delete it (it
    // never had an existence independent of a note).
    var hasBeenOrphaned: Bool
    // Every distinct surface string the user has actually saved for this card —
    // 食べた, 食べる, 食べます, etc. for the same verb. Per-surface star state
    // in the segment list reads this set: yellow only when the queried surface
    // is a member. Stored cards normalize their `surface` field to the lemma,
    // and add the user's clicked surface to this set; legacy cards (saved
    // before this field existed) decode with `Set([surface])`, and the
    // segment list adds the derived lemma in-memory at render time so they
    // appear yellow on both surface and lemma rows without a write migration.
    var encounteredSurfaces: Set<String>
    // User-created word list memberships, keyed by WordList.id.
    var wordListIDs: [UUID]
    // Free-form personal note attached by the user — mnemonic, context, etc.
    var personalNote: String?
    // When the word was first saved — used for newest/oldest sort.
    let savedAt: Date
    // Whole-sense selections. Mutually exclusive with selectedGlosses *for the same sense* —
    // see WordsStore.applySelection for the enforced invariant. Empty means "no whole-sense
    // selections."
    var selectedSenseIDs: [Int64]
    // Gloss-level selections — one entry per specific synonym the user pinned. Mutually
    // exclusive with selectedSenseIDs at the sense granularity (see invariant above).
    var selectedGlosses: [GlossRef]
    // The kana reading the user picked with the detail view's reading switcher (涙 なみだ ↔ なだ),
    // as a plain dictionary reading — never an inflected projection, so it reads correctly against
    // the stored lemma surface. Nil means "no explicit choice", and every reader falls back to the
    // entry's own preferred kana as before. Persisted because the switcher's effect has to outlive
    // the open detail view: the Words list row, the detail header on reopen, and the study cards
    // all read this. Cross-entry heteronym flips (抱く いだく ↔ だく) re-point the card to the other
    // entry AND record the reading here, so both halves of the switcher survive.
    var selectedReading: String?
    // Everything below was formerly owned by a separate ReviewStore, keyed by canonicalEntryID in
    // its own persisted dictionaries. Merged directly onto the card so there's one store, one
    // persisted array, and no risk of the two drifting out of sync or silently disagreeing about
    // which words exist. See WordsStore's "MARK: - Review" section for the derived Set/Dictionary
    // caches (learned/notLearned/mastered/stats) that give O(1) lookups back despite the data now
    // living per-card instead of in dedicated collections.
    var learnedMark: LearnedState
    var mastered: Bool
    // Transient "currently in the wrong pile" flag — true after an "again" answer, cleared by the
    // next "correct" one. Was ReviewStore.markedWrong.
    var markedWrong: Bool
    // SRS/accuracy history. Nil means never reviewed.
    var reviewStats: ReviewWordStats?

    var id: Int64 {
        canonicalEntryID
    }

    // Creates a saved-word value with optional note-list and word-list memberships.
    // `encounteredSurfaces` defaults to `[surface]` so call sites that already pass a
    // surface get a sensible per-surface star state without having to spell it out.
    init(canonicalEntryID: Int64, surface: String, sourceNoteIDs: [UUID] = [], wordListIDs: [UUID] = [], personalNote: String? = nil, savedAt: Date = Date(), selectedSenseIDs: [Int64] = [], selectedGlosses: [GlossRef] = [], encounteredSurfaces: Set<String>? = nil, entSeq: Int64? = nil, hasBeenOrphaned: Bool? = nil, selectedReading: String? = nil, learnedMark: LearnedState = .unmarked, mastered: Bool = false, markedWrong: Bool = false, reviewStats: ReviewWordStats? = nil) {
        self.canonicalEntryID = canonicalEntryID
        self.entSeq = entSeq
        self.surface = surface
        self.sourceNoteIDs = sourceNoteIDs
        self.wordListIDs = wordListIDs
        self.personalNote = personalNote
        self.savedAt = savedAt
        self.selectedSenseIDs = selectedSenseIDs
        self.selectedGlosses = selectedGlosses
        self.selectedReading = selectedReading
        self.learnedMark = learnedMark
        self.mastered = mastered
        self.markedWrong = markedWrong
        self.reviewStats = reviewStats
        // nil → seed with the surface so a freshly-saved card has one encountered
        // member and stars correctly without extra wiring at every call site.
        self.encounteredSurfaces = encounteredSurfaces ?? Set([surface])
        // nil → true only if this card is being created with no note attribution at all
        // (a standalone save), so callers that already know their own history don't have to
        // repeat sourceNoteIDs.isEmpty at every call site.
        self.hasBeenOrphaned = hasBeenOrphaned ?? sourceNoteIDs.isEmpty
    }

    // Custom decoder so saves persisted before the selection fields existed load with [].
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canonicalEntryID = try c.decode(Int64.self, forKey: .canonicalEntryID)
        // Legacy cards predate the stable key; nil here is backfilled on first post-dictionary load.
        entSeq = try c.decodeIfPresent(Int64.self, forKey: .entSeq)
        surface = try c.decode(String.self, forKey: .surface)
        sourceNoteIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceNoteIDs) ?? []
        wordListIDs = try c.decodeIfPresent([UUID].self, forKey: .wordListIDs) ?? []
        personalNote = try c.decodeIfPresent(String.self, forKey: .personalNote)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
        selectedSenseIDs = try c.decodeIfPresent([Int64].self, forKey: .selectedSenseIDs) ?? []
        selectedGlosses = try c.decodeIfPresent([GlossRef].self, forKey: .selectedGlosses) ?? []
        // Cards saved before the reading switcher persisted anything decode as nil, which is
        // exactly "no explicit choice" — readers fall back to the entry's preferred kana.
        selectedReading = try c.decodeIfPresent(String.self, forKey: .selectedReading)
        // Legacy cards (persisted before encounteredSurfaces existed) get seeded
        // with the stored surface as the sole encountered form. The segment-list
        // render path expands this in-memory with the derived lemma so legacy
        // cards starr on both surface and lemma rows — without writing back.
        encounteredSurfaces = try c.decodeIfPresent(Set<String>.self, forKey: .encounteredSurfaces) ?? Set([surface])
        // Cards persisted before this field existed have no recorded history, so it's inferred
        // from their current attribution: already-standalone cards are treated as having been
        // orphaned (the only honest reading of "currently zero notes"); already-attributed cards
        // are treated as never orphaned, since that's the closest available reading even though
        // their true history further back isn't recoverable.
        hasBeenOrphaned = try c.decodeIfPresent(Bool.self, forKey: .hasBeenOrphaned) ?? sourceNoteIDs.isEmpty
        // Cards persisted before the ReviewStore merge decode with the neutral/never-reviewed
        // defaults — WordsStore's one-time migration (mergeLegacyReviewStoreDataIfNeeded) backfills
        // real values from the old kioku.review.* keys on first load after the update.
        learnedMark = try c.decodeIfPresent(LearnedState.self, forKey: .learnedMark) ?? .unmarked
        mastered = try c.decodeIfPresent(Bool.self, forKey: .mastered) ?? false
        markedWrong = try c.decodeIfPresent(Bool.self, forKey: .markedWrong) ?? false
        reviewStats = try c.decodeIfPresent(ReviewWordStats.self, forKey: .reviewStats)
    }

    // Reconciles the stable key against the live dictionary, returning a corrected copy (or self
    // when nothing changes). If ent_seq is known, canonicalEntryID is re-resolved from it so a
    // dictionary rebuild can't leave the card pointing at a drifted row id. If ent_seq is missing
    // (legacy card), it is backfilled from the current canonicalEntryID — taken as-is, never
    // re-resolved by surface, so an already-mispointed card stays put until manually re-pointed.
    // Pure: the two lookups are injected as closures so this is testable without a DictionaryStore.
    func reconcilingStableKey(
        entSeqForEntryID: (Int64) -> Int64?,
        entryIDForEntSeq: (Int64) -> Int64?
    ) -> SavedWord {
        if let entSeq {
            let resolved = entryIDForEntSeq(entSeq) ?? canonicalEntryID
            guard resolved != canonicalEntryID else { return self }
            return copyWith(canonicalEntryID: resolved, entSeq: entSeq)
        } else {
            guard let backfilled = entSeqForEntryID(canonicalEntryID) else { return self }
            return copyWith(canonicalEntryID: canonicalEntryID, entSeq: backfilled)
        }
    }

    // Returns a copy with only the two stable-key fields replaced, preserving everything else.
    // canonicalEntryID and entSeq are both `let`, so this can't mutate a copy in place — every
    // field has to be threaded through explicitly. GUARD AGAINST RECURRENCE: if a field is ever
    // added to SavedWord without adding it here too, reconcilingStableKey (called on every
    // dictionary-ready reconcile and every persist()) silently resets it to default.
    private func copyWith(canonicalEntryID: Int64, entSeq: Int64?) -> SavedWord {
        SavedWord(
            canonicalEntryID: canonicalEntryID,
            surface: surface,
            sourceNoteIDs: sourceNoteIDs,
            wordListIDs: wordListIDs,
            personalNote: personalNote,
            savedAt: savedAt,
            selectedSenseIDs: selectedSenseIDs,
            selectedGlosses: selectedGlosses,
            encounteredSurfaces: encounteredSurfaces,
            entSeq: entSeq,
            hasBeenOrphaned: hasBeenOrphaned,
            selectedReading: selectedReading,
            learnedMark: learnedMark,
            mastered: mastered,
            markedWrong: markedWrong,
            reviewStats: reviewStats
        )
    }

    // Builds a non-persisted SavedWord wrapping a DictionaryEntry so a tap on a related/synonym
    // or common-word row can present a nested WordDetailView for it. Surface picks the same
    // headword the row displays (first everyday kanji → first kanji form → first kana form).
    // entSeq is left nil because DictionaryEntry doesn't carry it — if the user saves the word
    // from inside the nested view, WordsStore.toggle resolves the stable key from the store at
    // write time, so the ephemeral record never persists as-is.
    static func ephemeral(for entry: DictionaryEntry) -> SavedWord {
        let surface = entry.firstEverydayKanji?.text
            ?? entry.kanjiForms.first?.text
            ?? entry.kanaForms.first?.text
            ?? ""
        return SavedWord(canonicalEntryID: entry.entryId, surface: surface)
    }

    // Keeps saved-word identity stable across surface variants that map to the same dictionary entry.
    static func == (lhs: SavedWord, rhs: SavedWord) -> Bool {
        lhs.canonicalEntryID == rhs.canonicalEntryID
    }

    // Hashes by canonical entry identity so sets and dictionaries are keyed by dictionary entry id.
    func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalEntryID)
    }
}
