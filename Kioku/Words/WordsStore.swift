import Combine
import Foundation
import SwiftUI

// Box that lets the persist queue ship a UserDefaults across the Sendable boundary even
// though Foundation hasn't yet annotated UserDefaults as Sendable. Apple documents
// UserDefaults as thread-safe; this box is the one place we encode that promise.
// Module-internal rather than file-private because SavedKanjiStore reuses the same
// capture pattern for its persistQueue and we want one canonical helper, not two.
nonisolated final class UncheckedSendableUserDefaults: @unchecked Sendable {
    let value: UserDefaults
    init(value: UserDefaults) { self.value = value }
}

// Owns saved-word persistence for the Words tab. Replaces direct UserDefaults access in WordsView.
@MainActor
final class WordsStore: ObservableObject {
    @Published private(set) var words: [SavedWord] = []

    // nonisolated(unsafe) on userDefaults because UserDefaults isn't formally Sendable
    // in the SDK but Apple documents it as thread-safe — the persist() background
    // dispatch needs to capture it without the @MainActor isolation of WordsStore
    // making sending it a race per Swift 6 strict checking.
    nonisolated(unsafe) private let userDefaults: UserDefaults
    nonisolated private let storageKey: String

    // Both the UserDefaults instance and the storage key are parameterized so tests can scope
    // each case to a per-suite UserDefaults without leaking into .standard. Production callers
    // get the defaults and keep using the v1 key.
    init(userDefaults: UserDefaults = .standard, storageKey: String = "kioku.words.v1") {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        let key = storageKey
        let defaults = userDefaults
        let loaded = StartupTimer.measure("WordsStore.init") {
            SavedWordStorage.loadSavedWords(storageKey: key, userDefaults: defaults)
        }
        let migrated = WordsStore.mergingLegacyReviewStoreData(into: loaded, userDefaults: defaults)
        words = migrated
        lifetimeCorrect = defaults.integer(forKey: WordsStore.lifetimeCorrectKey)
        lifetimeAgain = defaults.integer(forKey: WordsStore.lifetimeAgainKey)
        refreshReviewCaches()
        // The migration reads from (and clears) the legacy kioku.review.* keys — if it actually
        // changed anything, write the merged data into kioku.words.v1 immediately so it isn't
        // re-derived from those now-cleared keys again, and isn't lost if the app is killed
        // before anything else triggers a save.
        if migrated.map(\.canonicalEntryID) != loaded.map(\.canonicalEntryID) || zip(migrated, loaded).contains(where: { $0.learnedMark != $1.learnedMark || $0.mastered != $1.mastered || $0.markedWrong != $1.markedWrong || $0.reviewStats != $1.reviewStats }) {
            persist(migrated)
        }
    }

    // Closures over the dictionary's ent_seq maps, installed once the dictionary is ready. While
    // nil (before the dictionary loads), saves persist with entSeq unresolved and get reconciled
    // when migration is enabled. nonisolated(unsafe) for the same reason as userDefaults: the
    // captured DictionaryStore is documented thread-safe (nonisolated, read-only after populate).
    private var stableKeyResolver: (entSeqForEntryID: (Int64) -> Int64?, entryIDForEntSeq: (Int64) -> Int64?)?

    // MARK: - Review
    //
    // Formerly a separate ReviewStore class with its own persisted dictionaries, keyed by
    // canonicalEntryID and prone to drifting out of sync with WordsStore (a word's card and its
    // study history could independently exist or not exist). Merged so a SavedWord's Learned mark,
    // mastery, and SRS stats are just more fields on the one row that word already has here —
    // deleting a word deletes its whole row, review history included, with no separate store or
    // setting to keep them artificially in sync.
    //
    // The four collections below are DERIVED from `words` (recomputed in refreshReviewCaches(),
    // called from init and persist()) rather than stored independently — `words` stays the single
    // source of truth for what gets encoded to disk. They exist purely so call sites that need
    // O(1) membership checks (list filtering, row rendering) don't have to linear-scan `words`
    // themselves; every call site works identically to when these lived on ReviewStore.
    @Published private(set) var learned: Set<Int64> = []
    @Published private(set) var notLearned: Set<Int64> = []
    @Published private(set) var mastered: Set<Int64> = []
    @Published private(set) var markedWrong: Set<Int64> = []
    @Published private(set) var stats: [Int64: ReviewWordStats] = [:]

    // Lifetime correct/again counts are the one piece of review data that ISN'T per-word — they're
    // a running total across every review ever done, including for words later deleted (removing
    // a card shouldn't erase how many reviews you've ever done). Kept as their own UserDefaults
    // values under the same keys ReviewStore used, so they survive the merge untouched.
    @Published private(set) var lifetimeCorrect: Int = 0
    @Published private(set) var lifetimeAgain: Int = 0
    private static let lifetimeCorrectKey = "kioku.review.lifetimeCorrect.v1"
    private static let lifetimeAgainKey = "kioku.review.lifetimeAgain.v1"

    // Writes the two lifetime counters to UserDefaults.
    private func persistLifetime() {
        userDefaults.set(lifetimeCorrect, forKey: WordsStore.lifetimeCorrectKey)
        userDefaults.set(lifetimeAgain, forKey: WordsStore.lifetimeAgainKey)
    }

    // Zeroes the lifetime counters — used by Settings' "Reset All Data", alongside
    // replaceAll(with: []) clearing every word's per-word review fields.
    func resetLifetimeCounts() {
        lifetimeCorrect = 0
        lifetimeAgain = 0
        persistLifetime()
    }

    // Overall correct / (correct + again) ratio across all sessions; nil when no reviews recorded.
    var lifetimeAccuracy: Double? {
        let total = lifetimeCorrect + lifetimeAgain
        guard total > 0 else { return nil }
        return Double(lifetimeCorrect) / Double(total)
    }

    // Rebuilds the derived caches above from `words`. Called whenever `words` changes (persist())
    // so the caches never have a chance to disagree with the array they're derived from.
    private func refreshReviewCaches() {
        var learnedSet = Set<Int64>()
        var notLearnedSet = Set<Int64>()
        var masteredSet = Set<Int64>()
        var wrongSet = Set<Int64>()
        var statsDict: [Int64: ReviewWordStats] = [:]
        for word in words {
            switch word.learnedMark {
            case .learned: learnedSet.insert(word.canonicalEntryID)
            case .notLearned: notLearnedSet.insert(word.canonicalEntryID)
            case .unmarked: break
            }
            if word.mastered { masteredSet.insert(word.canonicalEntryID) }
            if word.markedWrong { wrongSet.insert(word.canonicalEntryID) }
            if let reviewStats = word.reviewStats { statsDict[word.canonicalEntryID] = reviewStats }
        }
        learned = learnedSet
        notLearned = notLearnedSet
        mastered = masteredSet
        markedWrong = wrongSet
        stats = statsDict
    }

    // The current tri-state mark for a word, derived from the two mutually-exclusive sets above
    // (or read straight off the card, equivalently).
    func learnedState(for id: Int64) -> LearnedState {
        words.first(where: { $0.canonicalEntryID == id })?.learnedMark ?? .unmarked
    }

    // Sets the tri-state mark. A no-op on an unsaved entry — there's no card to mark. The single
    // write path for both the star long-press menu and the auto-learn promotion in recordCorrect.
    func setLearnedState(_ state: LearnedState, for id: Int64) {
        guard words.contains(where: { $0.canonicalEntryID == id }) else { return }
        var updated = words
        if let idx = updated.firstIndex(where: { $0.canonicalEntryID == id }) {
            updated[idx].learnedMark = state
        }
        persist(updated)
    }

    // True when the word has been marked learned (manually or automatically).
    func isLearned(id: Int64) -> Bool { learned.contains(id) }

    // True when the word has been explicitly marked not-learned.
    func isNotLearned(id: Int64) -> Bool { notLearned.contains(id) }

    // What's on file about the word having a kanji form, or nil when no study mode has yet recorded
    // an answer for it with dictionary data in hand.
    func hasKanjiForm(for id: Int64) -> Bool? { stats[id]?.hasKanjiForm }

    // The canonical mastery stage for a word — New/Learning/Learned/Mastered.
    func masteryStage(for id: Int64) -> MasteryStage {
        if mastered.contains(id) { return .mastered }
        if learnedState(for: id) == .learned { return .learned }
        if stats[id] != nil || learnedState(for: id) == .notLearned { return .learning }
        return .new
    }

    // True when the word is due — never reviewed (no stats) or its `dueDate` has elapsed.
    func isDue(id: Int64, at date: Date = Date()) -> Bool {
        guard let st = stats[id] else { return true }
        guard let due = st.dueDate else { return true }
        return due <= date
    }

    // True only when the word has been reviewed before AND its scheduled interval has lapsed.
    func isDueForReview(id: Int64, at date: Date = Date()) -> Bool {
        guard let st = stats[id], let due = st.dueDate else { return false }
        return due <= date
    }

    // Number of saved words currently due for review.
    func dueCount(among wordsList: [SavedWord], at date: Date = Date()) -> Int {
        wordsList.reduce(0) { $0 + (isDue(id: $1.canonicalEntryID, at: date) ? 1 : 0) }
    }

    // Records a correct answer: increments counters, clears the wrong flag, and reschedules the
    // card via SRSScheduler so it reappears at the next interval up the ladder. A no-op on an
    // unsaved entry.
    func recordCorrect(for id: Int64, direction: QuestionDirection? = nil, hasKanjiForm: Bool? = nil) {
        guard let idx = words.firstIndex(where: { $0.canonicalEntryID == id }) else { return }
        var updated = words
        var word = updated[idx]
        let prior = word.reviewStats
        var st = prior ?? ReviewWordStats(correct: 0, again: 0)
        if let hasKanjiForm { st.hasKanjiForm = hasKanjiForm }
        st.correct += 1
        let now = Date()
        st.lastReviewedAt = now
        let schedule = SRSScheduler.schedule(previous: prior, answer: .correct, now: now)
        st.dueDate = schedule.dueDate
        st.consecutiveCorrect = schedule.consecutiveCorrect
        if let direction { st.recordDirectionAnswer(direction, correct: true) }
        word.reviewStats = st
        word.markedWrong = false
        lifetimeCorrect += 1
        // Auto-promote to "learned" when every recognition direction's evidence clears whatever
        // bar the user configured in Settings. Only acts on a word the user hasn't marked either
        // way (unmarked) — an explicit Learned is already done, and an explicit Not Learned is a
        // deliberate signal we don't override from behind their back.
        if word.learnedMark == .unmarked,
           AutoLearnPolicy.shouldMarkLearned(directionStats: st.directionStats, hasKanjiForm: st.hasKanjiForm ?? true) {
            word.learnedMark = .learned
        }
        // Auto-promote to "mastered" once every direction — recognition AND production — clears
        // the bar too. Doesn't require `.unmarked`: mastery normally follows an already-Learned
        // word, so it only excludes an explicit "not learned" mark.
        if word.learnedMark != .notLearned, word.mastered == false,
           AutoLearnPolicy.shouldMarkMastered(directionStats: st.directionStats, hasKanjiForm: st.hasKanjiForm ?? true) {
            word.mastered = true
        }
        updated[idx] = word
        persistLifetime()
        persist(updated)
    }

    // Records an "again" answer: increments counters, sets the wrong flag, resets the SRS streak,
    // and reschedules the card to reappear after the short relearn step. A no-op on an unsaved entry.
    func recordAgain(for id: Int64, direction: QuestionDirection? = nil, hasKanjiForm: Bool? = nil) {
        guard let idx = words.firstIndex(where: { $0.canonicalEntryID == id }) else { return }
        var updated = words
        var word = updated[idx]
        let prior = word.reviewStats
        var st = prior ?? ReviewWordStats(correct: 0, again: 0)
        if let hasKanjiForm { st.hasKanjiForm = hasKanjiForm }
        st.again += 1
        let now = Date()
        st.lastReviewedAt = now
        let schedule = SRSScheduler.schedule(previous: prior, answer: .again, now: now)
        st.dueDate = schedule.dueDate
        st.consecutiveCorrect = schedule.consecutiveCorrect
        if let direction { st.recordDirectionAnswer(direction, correct: false) }
        word.reviewStats = st
        word.markedWrong = true
        lifetimeAgain += 1
        updated[idx] = word
        persistLifetime()
        persist(updated)
    }

    // Replaces the review side of every card in one pass — used only by app-backup restore, which
    // ships review data as a separate legacy payload section (pre-dating the merge) keyed by
    // canonicalEntryID. Words with no matching entry in any of the sets/dict are left at their
    // (already-merged, from the words array itself) defaults.
    func applyLegacyReviewBackup(
        stats reviewStats: [Int64: ReviewWordStats],
        markedWrong wrongIDs: Set<Int64>,
        learned learnedIDs: Set<Int64>,
        notLearned notLearnedIDs: Set<Int64>,
        mastered masteredIDs: Set<Int64>,
        lifetimeCorrect: Int,
        lifetimeAgain: Int
    ) {
        let updated = words.map { word -> SavedWord in
            var word = word
            if let s = reviewStats[word.canonicalEntryID] { word.reviewStats = s }
            if learnedIDs.contains(word.canonicalEntryID) { word.learnedMark = .learned }
            else if notLearnedIDs.contains(word.canonicalEntryID) { word.learnedMark = .notLearned }
            word.mastered = masteredIDs.contains(word.canonicalEntryID)
            word.markedWrong = wrongIDs.contains(word.canonicalEntryID)
            return word
        }
        self.lifetimeCorrect = lifetimeCorrect
        self.lifetimeAgain = lifetimeAgain
        persistLifetime()
        persist(updated)
    }

    // One-time migration off the pre-merge ReviewStore's separate UserDefaults keys, run from
    // init before `words` is ever published. Reads (and, on a real match, clears) the legacy
    // kioku.review.* keys and folds their data into the matching SavedWord rows by
    // canonicalEntryID. A no-op — cheap, since the guard bails before touching UserDefaults
    // further — for new installs and for anyone who's already been through this once (the keys
    // are gone by then). `static` so it can run before `self` is fully initialized.
    private static func mergingLegacyReviewStoreData(into words: [SavedWord], userDefaults: UserDefaults) -> [SavedWord] {
        guard let statsData = userDefaults.data(forKey: "kioku.review.stats.v1") else { return words }
        let legacyStats: [Int64: ReviewWordStats] = (try? JSONDecoder().decode([String: ReviewWordStats].self, from: statsData))
            .map { decoded in
                decoded.reduce(into: [Int64: ReviewWordStats]()) { result, pair in
                    if let id = Int64(pair.key) { result[id] = pair.value }
                }
            } ?? [:]
        let legacyLearned = Set((userDefaults.array(forKey: "kioku.review.learned.v1") as? [String] ?? []).compactMap { Int64($0) })
        let legacyNotLearned = Set((userDefaults.array(forKey: "kioku.review.notLearned.v1") as? [String] ?? []).compactMap { Int64($0) })
        let legacyMastered = Set((userDefaults.array(forKey: "kioku.review.mastered.v1") as? [String] ?? []).compactMap { Int64($0) })
        let legacyWrong = Set((userDefaults.array(forKey: "kioku.review.wrong.v1") as? [String] ?? []).compactMap { Int64($0) })

        let migrated = words.map { word -> SavedWord in
            var word = word
            if let s = legacyStats[word.canonicalEntryID] { word.reviewStats = s }
            if legacyLearned.contains(word.canonicalEntryID) { word.learnedMark = .learned }
            else if legacyNotLearned.contains(word.canonicalEntryID) { word.learnedMark = .notLearned }
            if legacyMastered.contains(word.canonicalEntryID) { word.mastered = true }
            if legacyWrong.contains(word.canonicalEntryID) { word.markedWrong = true }
            return word
        }
        // Cleared so this migration can't re-run (and clobber later manual edits) on a future
        // launch. Lifetime counters are left alone — WordsStore reads them directly under the
        // same keys ReviewStore used, no migration needed for those.
        userDefaults.removeObject(forKey: "kioku.review.stats.v1")
        userDefaults.removeObject(forKey: "kioku.review.wrong.v1")
        userDefaults.removeObject(forKey: "kioku.review.learned.v1")
        userDefaults.removeObject(forKey: "kioku.review.notLearned.v1")
        userDefaults.removeObject(forKey: "kioku.review.mastered.v1")
        return migrated
    }

    // Installs the stable-key resolver and reconciles existing saved words against the live
    // dictionary: legacy cards get their ent_seq backfilled from the current row id, and cards with
    // a known ent_seq get canonicalEntryID re-resolved so a dictionary rebuild can't leave them
    // pointing at a drifted row. Idempotent — safe to call again if the dictionary reloads. Call
    // once the dictionary is ready (ContentView's readResources.ready hook).
    func enableStableKeyMigration(using store: DictionaryStore) {
        let resolver = (
            entSeqForEntryID: { store.entSeq(forEntryID: $0) },
            entryIDForEntSeq: { store.entryID(forEntSeq: $0) }
        )
        stableKeyResolver = resolver
        let reconciled = words.map {
            $0.reconcilingStableKey(entSeqForEntryID: resolver.entSeqForEntryID, entryIDForEntSeq: resolver.entryIDForEntSeq)
        }
        // SavedWord's == ignores entSeq (identity is the entry), so compare the stable-key fields
        // explicitly to avoid a spurious write+publish when nothing actually changed.
        let changed = reconciled.count != words.count || zip(words, reconciled).contains {
            $0.canonicalEntryID != $1.canonicalEntryID || $0.entSeq != $1.entSeq
        }
        if changed { persist(reconciled) }
    }

    // Adds a word or merges it with an existing entry if already saved.
    func add(_ word: SavedWord) {
        var updated = words
        updated.append(word)
        persist(updated)
    }

    // Adds many words in one persist cycle. Bulk callers (CSV import, batch saves) must use this
    // instead of looping over add(_:) so they trigger one normalize + encode + UserDefaults write
    // instead of N — a per-item loop blocks the main thread for hundreds of milliseconds on large
    // imports because each iteration round-trips through JSON and UserDefaults.
    func add(_ newWords: [SavedWord]) {
        guard !newWords.isEmpty else { return }
        persist(words + newWords)
    }

    // Removes a word by canonical entry id. Its review history (learned mark, mastery, SRS stats)
    // goes with it — they're fields on this same row now, not a separate store, so there's no
    // second step to keep in sync.
    func remove(id: Int64) {
        persist(words.filter { $0.canonicalEntryID != id })
    }

    // Removes many words in one persist cycle. Bulk callers (multi-select delete in WordsView)
    // must use this instead of looping over remove(id:) so the persist work is paid once, not N
    // times — the per-item loop is the source of the UI freeze when deleting many words.
    func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        persist(words.filter { !ids.contains($0.canonicalEntryID) })
    }

    // Detaches deleted-note provenance without deleting saved vocabulary.
    func detachNoteReferences(noteIDs: Set<UUID>) {
        guard noteIDs.isEmpty == false else { return }
        let updated = words.map { word in
            var detached = word
            detached.sourceNoteIDs.removeAll { noteIDs.contains($0) }
            // Explicitly preserved rather than deleted (see the comment above), so if that
            // leaves it with zero attribution it's now a genuine orphan going forward.
            if detached.sourceNoteIDs.isEmpty {
                detached.hasBeenOrphaned = true
            }
            return detached
        }
        persist(updated)
    }

    // Re-points a saved card to a different dictionary entry — the fix for a card that
    // resolved to the wrong lemma (e.g. した saved as 下 when the user meant the verb する).
    // List membership, personal note, source notes, and save date carry over; the old surface
    // folds into encounteredSurfaces; sense/gloss selections reset because they reference the
    // OLD entry's senses. If the target entry is already saved, the two cards merge onto it
    // (union of lists/notes/surfaces) so identity (keyed by canonicalEntryID) stays unique.
    // The OLD card's `selectedReading` is dropped for the same reason as the selections: it named a
    // kana form of the OLD entry. The TARGET's own reading is kept, though — it names a kana form of
    // newID and is still valid, so merging a card onto an entry the user had already pinned a
    // reading on must not reset that entry to its dictionary default. The reading switcher, whose
    // heteronym flips route through here, then overwrites with setReading; the lemma-picker and
    // sense-card re-points don't, which is exactly why the target's value has to survive on its own.
    func repoint(fromEntryID oldID: Int64, toEntryID newID: Int64, lemma: String) {
        guard oldID != newID,
              let old = words.first(where: { $0.canonicalEntryID == oldID }) else { return }

        let existing = words.first(where: { $0.canonicalEntryID == newID })

        var encountered = old.encounteredSurfaces
        encountered.insert(old.surface)
        if let existing { encountered.formUnion(existing.encounteredSurfaces) }

        let mergedLists = Array(Set(old.wordListIDs).union(existing?.wordListIDs ?? []))
        let mergedNotes = Array(Set(old.sourceNoteIDs).union(existing?.sourceNoteIDs ?? []))

        let repointed = SavedWord(
            canonicalEntryID: newID,
            surface: lemma,
            sourceNoteIDs: mergedNotes,
            wordListIDs: mergedLists,
            personalNote: old.personalNote ?? existing?.personalNote,
            savedAt: old.savedAt,
            selectedSenseIDs: [],
            selectedGlosses: [],
            encounteredSurfaces: encountered,
            hasBeenOrphaned: old.hasBeenOrphaned || (existing?.hasBeenOrphaned ?? false),
            selectedReading: existing?.selectedReading,
            // Review history follows the correction like everything else here — prefer the
            // target entry's own accumulated history if it already had any (that's the TRUE
            // record for the entry the user is actually being corrected onto), else carry over
            // what had built up under the mispointed old entry rather than discarding it.
            learnedMark: existing?.learnedMark ?? old.learnedMark,
            mastered: existing?.mastered ?? old.mastered,
            markedWrong: existing?.markedWrong ?? old.markedWrong,
            reviewStats: existing?.reviewStats ?? old.reviewStats
        )

        // Keep the card roughly where the old one sat; drop both old and any target collision first.
        let insertIndex = words.firstIndex(where: { $0.canonicalEntryID == oldID }) ?? words.count
        var updated = words.filter { $0.canonicalEntryID != oldID && $0.canonicalEntryID != newID }
        updated.insert(repointed, at: min(insertIndex, updated.count))
        persist(updated)
    }

    // Toggles membership of a word in a word list; adds if absent, removes if present.
    func toggleListMembership(wordID: Int64, listID: UUID) {
        persist(words.map { word in
            guard word.canonicalEntryID == wordID else { return word }
            var updated = word
            if updated.wordListIDs.contains(listID) {
                updated.wordListIDs.removeAll { $0 == listID }
            } else {
                updated.wordListIDs.append(listID)
            }
            return updated
        })
    }

    // Detaches one word from one note (e.g. "Remove from <note>" on a row viewed under a
    // note filter). The word stays saved — note attribution is just one of its attributes —
    // it simply drops out of that note's filtered view.
    func removeNoteMembership(wordID: Int64, noteID: UUID) {
        persist(words.map { word in
            guard word.canonicalEntryID == wordID, word.sourceNoteIDs.contains(noteID) else { return word }
            var updated = word
            updated.sourceNoteIDs.removeAll { $0 == noteID }
            // Never deleted here, so a drop to zero attribution is a real orphan going forward.
            if updated.sourceNoteIDs.isEmpty {
                updated.hasBeenOrphaned = true
            }
            return updated
        })
    }

    // Strips a deleted list id from all saved words so no orphan memberships remain.
    func removeListMembership(listID: UUID) {
        persist(words.map { word in
            guard word.wordListIDs.contains(listID) else { return word }
            var updated = word
            updated.wordListIDs.removeAll { $0 == listID }
            return updated
        })
    }

    // Adds all specified word ids to a list. Words already in the list are unchanged.
    func addToList(wordIDs: Set<Int64>, listID: UUID) {
        persist(words.map { word in
            guard wordIDs.contains(word.canonicalEntryID), !word.wordListIDs.contains(listID) else { return word }
            var updated = word
            updated.wordListIDs.append(listID)
            return updated
        })
    }

    // Removes all specified word ids from a list. Words not in the list are unchanged.
    func removeFromList(wordIDs: Set<Int64>, listID: UUID) {
        persist(words.map { word in
            guard wordIDs.contains(word.canonicalEntryID), word.wordListIDs.contains(listID) else { return word }
            var updated = word
            updated.wordListIDs.removeAll { $0 == listID }
            return updated
        })
    }

    // Updates the personal note on a saved word.
    func updatePersonalNote(id: Int64, note: String?) {
        persist(words.map { word in
            guard word.canonicalEntryID == id else { return word }
            var updated = word
            updated.personalNote = note
            return updated
        })
    }

    // Replaces both selection arrays for one saved word in a single persist pass.
    // Callers (the WordDetailView picker) compute the post-toggle state including any
    // mutual-exclusion fold (whole sense vs. its glosses) before calling.
    func setSelection(id: Int64, senseIDs: [Int64], glosses: [GlossRef]) {
        persist(words.map { word in
            guard word.canonicalEntryID == id else { return word }
            var updated = word
            updated.selectedSenseIDs = senseIDs
            updated.selectedGlosses = glosses
            return updated
        })
    }

    // Records (or clears, with nil) the kana reading the user picked for one saved word via the
    // detail view's reading switcher. Separate from setSelection because the reading axis is
    // independent of the sense/gloss axis — flipping 涙 to なだ must not disturb which definitions
    // are pinned, and vice versa. A no-op on an unsaved entry: there's no card to record it on.
    func setReading(id: Int64, reading: String?) {
        guard words.contains(where: { $0.canonicalEntryID == id }) else { return }
        persist(words.map { word in
            guard word.canonicalEntryID == id else { return word }
            var updated = word
            updated.selectedReading = reading
            return updated
        })
    }

    // Reorders words in response to a drag-and-drop move gesture from the list.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        var updated = words
        updated.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist(updated)
    }

    // Reloads the published words array from persistent storage. Called by external writers (e.g. SegmentListView) to keep the store in sync after a direct persist.
    func reload() {
        words = SavedWordStorage.loadSavedWords(storageKey: storageKey, userDefaults: userDefaults)
        refreshReviewCaches()
    }

    // Replaces the saved-word store with one canonical snapshot.
    func replaceAll(with words: [SavedWord]) {
        persist(words)
    }

    // Canonical save/unsave entry point. All UI surfaces (Words tab search, history rows,
    // browse-frequency sheet, segment-list star, in-text lookup-sheet star, nested-lookup
    // star) go through this method so the bookkeeping stays in one place — encountered-
    // surface tracking, per-note attribution, default sense-ID seeding, and card-removal
    // semantics can't drift between surfaces.
    //
    // Toggle semantics: for an existing card, flip membership of `encounteredSurface` in
    // the card's `encounteredSurfaces` set and of `sourceNoteID` in its `sourceNoteIDs`
    // attribution. The card is removed only when BOTH sets become empty — so a "save"
    // attributed to one note doesn't accidentally remove the card's attribution from
    // another note. For a brand-new card, the stored surface is lemma-normalized at
    // create time (callers pass the lemma form as `storedSurface` and the encountered
    // form — the user's clicked surface — as `encounteredSurface`), so star state on
    // the lemma row and the encountered row both light up correctly.
    //
    // Callers without segment context (Words tab, history, browse) pass nil for
    // `encounteredSurface` (defaulting to `storedSurface`) and nil for `sourceNoteID`,
    // which collapses to "toggle the card globally" — the card is removed when its
    // only encountered surface is the toggled one and no note attributions exist.
    func toggle(
        canonicalEntryID: Int64,
        storedSurface: String,
        encounteredSurface: String? = nil,
        sourceNoteID: UUID? = nil,
        defaultSenseIDs: [Int64] = []
    ) {
        let encountered = encounteredSurface ?? storedSurface
        var entries = words
        if let existingIndex = entries.firstIndex(where: { $0.canonicalEntryID == canonicalEntryID }) {
            let existingEntry = entries[existingIndex]
            var encounteredSet = existingEntry.encounteredSurfaces
            var noteIDs = Set(existingEntry.sourceNoteIDs)

            let surfaceWasInSet = encounteredSet.contains(encountered)
            let noteWasAttached = sourceNoteID.map { noteIDs.contains($0) } ?? false
            // "Saved here" must mirror ComputedSavedWordState.isStarFilled — the predicate that
            // decides whether the star renders filled — or a single tap on an already-filled
            // star can silently no-op (attach this note to a globally-saved card, which the
            // star still renders as filled) instead of removing it, requiring a second tap.
            // Filled means: attributed to this note, OR saved with no note attribution at all
            // (`noteIDs.isEmpty`) — a global save with zero note attributions. Without a note
            // context, surface membership alone determines it.
            let wasSavedHere: Bool = {
                guard sourceNoteID != nil else { return surfaceWasInSet }
                return surfaceWasInSet && (noteWasAttached || noteIDs.isEmpty)
            }()

            if wasSavedHere {
                encounteredSet.remove(encountered)
                if let sourceNoteID, encounteredSet.isEmpty {
                    // Last encountered surface gone for this card → drop this note's
                    // attribution. The card disappears entirely if no other note
                    // still has it on file.
                    noteIDs.remove(sourceNoteID)
                }
            } else {
                encounteredSet.insert(encountered)
                if let sourceNoteID {
                    noteIDs.insert(sourceNoteID)
                }
            }

            if encounteredSet.isEmpty && noteIDs.isEmpty {
                // Only a true full removal (no encountered surfaces, no note attributions left
                // anywhere) counts as "unsaved" — detaching one note/surface while the card
                // survives elsewhere must NOT touch review data, and here the whole row (review
                // fields included) simply goes away with it.
                entries.remove(at: existingIndex)
            } else {
                let orderedNoteIDs = noteIDs.sorted { $0.uuidString < $1.uuidString }
                entries[existingIndex] = SavedWord(
                    canonicalEntryID: existingEntry.canonicalEntryID,
                    surface: existingEntry.surface,
                    sourceNoteIDs: orderedNoteIDs,
                    wordListIDs: existingEntry.wordListIDs,
                    personalNote: existingEntry.personalNote,
                    savedAt: existingEntry.savedAt,
                    selectedSenseIDs: existingEntry.selectedSenseIDs,
                    selectedGlosses: existingEntry.selectedGlosses,
                    encounteredSurfaces: encounteredSet,
                    entSeq: existingEntry.entSeq,
                    hasBeenOrphaned: existingEntry.hasBeenOrphaned || orderedNoteIDs.isEmpty,
                    // Toggling note/surface membership must not disturb the reading the user
                    // picked with the detail-view switcher — it's a display choice, not provenance.
                    selectedReading: existingEntry.selectedReading,
                    // Nor must it disturb the word's review history — GUARD AGAINST RECURRENCE:
                    // every field added to SavedWord has to be threaded through here too, or a
                    // plain note/surface toggle silently resets it (this is exactly the bug this
                    // comment exists to prevent for the review fields specifically).
                    learnedMark: existingEntry.learnedMark,
                    mastered: existingEntry.mastered,
                    markedWrong: existingEntry.markedWrong,
                    reviewStats: existingEntry.reviewStats
                )
            }
        } else {
            let noteIDs: [UUID] = sourceNoteID.map { [$0] } ?? []
            entries.append(
                SavedWord(
                    canonicalEntryID: canonicalEntryID,
                    surface: storedSurface,
                    sourceNoteIDs: noteIDs,
                    selectedSenseIDs: defaultSenseIDs,
                    encounteredSurfaces: [encountered]
                )
            )
        }

        replaceAll(with: entries)
    }

    // Normalizes on main (cheap, hashmap merge), publishes the new array immediately so
    // SwiftUI repaints on the same runloop tick, then dispatches the JSON encode +
    // UserDefaults write off-main on a SERIAL queue. The serial queue preserves write
    // ordering (so a rapid sequence of toggles can't land out-of-order on disk) and
    // avoids the snapshot-replace race: we never read back from the background path
    // into @Published `words`, so a newer main-thread mutation can't be clobbered by
    // a stale background write completing later.
    //
    // Durability tradeoff: a hard kill in the millisecond window between publish and
    // disk write loses the latest toggle. Acceptable for this use case — the user can
    // re-tap, and the alternative (sync write on main) was the bottleneck on the
    // star-tap path.
    private func persist(_ entries: [SavedWord]) {
        // Reconcile against the live dictionary so newly-added cards get their stable ent_seq
        // backfilled and any drifted row id is corrected before the write. No-op until the
        // dictionary is ready (resolver installed by enableStableKeyMigration).
        let reconciled = stableKeyResolver.map { resolver in
            entries.map {
                $0.reconcilingStableKey(entSeqForEntryID: resolver.entSeqForEntryID, entryIDForEntSeq: resolver.entryIDForEntSeq)
            }
        } ?? entries
        let normalized = SavedWordStorage.normalizedEntries(reconciled)
        words = normalized
        refreshReviewCaches()
        let storageKey = self.storageKey
        // UserDefaults isn't formally Sendable in the SDK but Apple documents it as
        // thread-safe — wrap in an @unchecked Sendable box so the persistQueue capture
        // satisfies Swift 6 strict-concurrency without spraying nonisolated(unsafe)
        // through every call-site.
        let userDefaults = UncheckedSendableUserDefaults(value: self.userDefaults)
        WordsStore.persistQueue.async {
            SavedWordStorage.writeNormalized(normalized, storageKey: storageKey, userDefaults: userDefaults.value)
        }
    }

    // Serial queue ensures writes land in the order they were dispatched, so rapid
    // toggles can't race each other into UserDefaults. Static so all WordsStore
    // instances share one queue (in practice there's one per app, plus per-test).
    private static let persistQueue = DispatchQueue(
        label: "matthewmorrone.Kioku.WordsStore.persist",
        qos: .utility
    )

    // Blocks until every previously dispatched persist write has completed. Used
    // by tests that construct a fresh WordsStore to verify on-disk state — without
    // this, the reader can race past an in-flight background write. Production code
    // never calls this: the next app launch always observes the latest write because
    // the queue drains long before then.
    static func flushPendingWritesForTesting() {
        persistQueue.sync {}
    }
}
