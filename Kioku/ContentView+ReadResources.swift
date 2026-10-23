import Foundation

// Startup build of the read-tab resources (dictionary store maps, trie, deinflector, segmenter),
// split out of ContentView so the parallel lanes read as one unit.
extension ContentView {
    // Builds the read-tab segmenter and dictionary store used for furigana lookup.
    //
    // Two lanes run side by side, each on its own SQLite connection: the store's in-memory maps
    // (canonical ids, ent_seq, POS bits, JLPT, kanji fallback) and the trie → deinflector →
    // segmenter chain, which never reads those maps. Run back to back they cost about 2 s before
    // the lexicon (and the saved-word coloring that waits on it) could publish; side by side the
    // wait is the longer lane. The caller runs the surface-reading scan beside both and builds
    // the Lexicon once everything has joined.
    nonisolated static func makeReadResources() async -> (segmenter: any TextSegmenting, dictionaryStore: DictionaryStore?, deinflector: Deinflector?, kanjiReadingFallback: KanjiReadingFallbackMap) {
        StartupTimer.mark("makeReadResources started")
        let overallStart = CFAbsoluteTimeGetCurrent()

        let dictionaryStore: DictionaryStore?
        do {
            dictionaryStore = try StartupTimer.measure("DictionaryStore.init") {
                try DictionaryStore()
            }
        } catch {
            AppLog.error(.dictionary, "DictionaryStore initialization failed: \(error)")
            dictionaryStore = nil
        }

        // The segmenter keeps this connection for its name-reading lookups; the maps lane mutates
        // dictionaryStore's in-memory maps, so the two lanes never share a store.
        let segmenterStore: DictionaryStore?
        do {
            segmenterStore = dictionaryStore == nil ? nil : try DictionaryStore()
        } catch {
            AppLog.error(.dictionary, "segmenter DictionaryStore initialization failed: \(error)")
            segmenterStore = nil
        }

        async let kanjiReadingFallback = prewarmStoreMaps(dictionaryStore)
        let (segmenter, deinflector) = buildSegmenter(store: segmenterStore)
        let fallback = await kanjiReadingFallback

        let overallElapsed = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
        StartupTimer.mark("makeReadResources total: \(String(format: "%.1f", overallElapsed)) ms")

        return (
            segmenter: segmenter,
            dictionaryStore: dictionaryStore,
            deinflector: deinflector,
            kanjiReadingFallback: KanjiReadingFallbackMap(fallback)
        )
    }

    // Fills the store's in-memory lookup maps before it is published, and returns the per-kanji
    // reading fallback. Its own lane in makeReadResources: none of it feeds the segmenter.
    nonisolated private static func prewarmStoreMaps(_ store: DictionaryStore?) -> [Character: String] {
        guard let store else { return [:] }

        // Populate the surface → canonical entry id map before publishing so all later
        // saved-word identity lookups (Add All, prewarm, CSV import) become hashtable
        // hits instead of per-surface SQL — eliminates the fallback storm that used to
        // dominate Add All latency.
        do { try StartupTimer.measure("populateCanonicalEntryIDMap") {
            try store.populateCanonicalEntryIDMap()
        }} catch {
            // An empty map makes every saved-word and extracted-vocab lookup miss at once
            // while segmentation still looks healthy, so a Debug build stops here.
            AppLog.error(.dictionary, "populateCanonicalEntryIDMap failed: \(error)")
            assertionFailure("populateCanonicalEntryIDMap failed: \(error)")
        }

        // ent_seq ⇄ row-id maps, so saved words keyed by the stable JMdict ent_seq can resolve
        // to the current (rebuild-unstable) row id.
        do { try StartupTimer.measure("populateEntSeqMaps") {
            try store.populateEntSeqMaps()
        }} catch { AppLog.error(.dictionary, "populateEntSeqMaps failed: \(error)") }

        // Surface → POS bits map. Used by Lexicon's deinflection pruning to gate
        // candidates without per-call SQL — the old hot path hit `posBits(for:)`
        // hundreds of times during a single tap because every BFS-generated
        // deinflection candidate needed an entry lookup just to check POS.
        do { try StartupTimer.measure("populateSurfacePOSBitsMap") {
            try store.populateSurfacePOSBitsMap()
        }} catch { AppLog.error(.dictionary, "populateSurfacePOSBitsMap failed: \(error)") }

        // entry_id → JLPT level map. Backs the Words JLPT filter and the Flashcards/Multiple
        // Choice level pickers with O(1) per-saved-word lookups instead of SQL. Empty (and
        // harmless) on a dictionary built before the entry_jlpt_level migration.
        do { try StartupTimer.measure("populateJLPTLevelMap") {
            try store.populateJLPTLevelMap()
        }} catch { AppLog.error(.dictionary, "populateJLPTLevelMap failed: \(error)") }

        // Last-resort per-kanji furigana source, so any kanji without a dictionary word/lemma
        // reading still gets *some* ruby (see KanjiReadingFallbackMap). ~13k kanji.
        do {
            return try StartupTimer.measure("fetchKanjiReadingFallbackMap") {
                try store.fetchKanjiReadingFallbackMap()
            }
        } catch {
            AppLog.error(.dictionary, "fetchKanjiReadingFallbackMap failed: \(error)")
            return [:]
        }
    }

    // Loads the trie and builds the deinflector and segmenter on top of it: the longest lane in
    // makeReadResources, and the one the lexicon waits on.
    nonisolated private static func buildSegmenter(store: DictionaryStore?) -> (segmenter: any TextSegmenting, deinflector: Deinflector?) {
        var trie = DictionaryTrie()
        // Per-entry POS bits, captured from the same surface-data scan that builds the trie.
        // Threaded into the trie-Viterbi Segmenter so its lemma-candidate POS gate can tell a
        // verb (する) from a noun — without it the gate sees all-zero bits and drops every
        // deinflected verb candidate (e.g. した → する).
        var partOfSpeechByEntryID: [Int: UInt64] = [:]
        var deinflector: Deinflector?

        if let store {
            do {
                // The trie saved on an earlier launch for this exact dictionary file, when there is
                // one: it only needs the per-entry POS bits beside it, not the 456k surface records.
                let snapshotKey = TrieSnapshotCache.key(store: store)
                if let snapshotKey, let restored = StartupTimer.measure("trie snapshot load", block: { TrieSnapshotCache.load(key: snapshotKey) }) {
                    trie = restored
                    partOfSpeechByEntryID = try StartupTimer.measure("fetchPartOfSpeechByEntryID") {
                        try store.fetchPartOfSpeechByEntryID()
                    }
                } else {
                    // SurfaceRecords carry the POS bits the path search classes each word by
                    // (TransitionClass). The fetch path aggregates
                    // POS per entry in a first pass (small) and join in-memory against surface rows
                    // in a second pass — avoids the JOIN-explosion that OOM-killed the app earlier.
                    let surfaceData = try StartupTimer.measure("fetchSurfaceData") {
                        try store.fetchSurfaceData()
                    }
                    partOfSpeechByEntryID = surfaceData.partOfSpeechByEntryID
                    StartupTimer.measure("trie population (\(surfaceData.surfaceRecords.count) records)") {
                        for record in surfaceData.surfaceRecords { trie.insert(record) }
                    }
                    // Saved for the next launch, off the startup path; the trie is only read from here on.
                    if let snapshotKey {
                        let builtTrie = trie
                        Task.detached(priority: .utility) {
                            StartupTimer.measure("trie snapshot save") {
                                TrieSnapshotCache.save(builtTrie, key: snapshotKey)
                            }
                        }
                    }
                }
            } catch { AppLog.error(.dictionary, "fetchSurfaceData failed: \(error)") }

            // The rules ship inside the dictionary (generated into it from UniDic and the grammar table).
            do {
                let ruleSet = try store.fetchDeinflectionRuleSet()
                deinflector = StartupTimer.measure("Deinflector.init") {
                    Deinflector(ruleSet: ruleSet, trie: trie)
                }
            } catch {
                AppLog.error(.dictionary, "Deinflector initialization failed: \(error)")
            }
        }

        let segmenter: any TextSegmenting = StartupTimer.measure("Segmenter.init") {
            Segmenter(
                trie: trie,
                deinflector: deinflector,
                partOfSpeechByEntryID: partOfSpeechByEntryID,
                frequenciesFrom: store
            )
        }
        return (segmenter, deinflector)
    }
}
