import Foundation

// Maps a surface to its distinct readings, each tied to a lemma, inflection chain, and JMdict entry.
// This is the gathering the Read-tab lookup sheet's left/right arrows cycle through, lifted out of
// the inline closures in ReadView+Segmentation so the Words-tab word detail screen can reuse the
// exact same reading set (e.g. 抱かれ → いだ / だ / うだ across the three homograph entries of 抱く).
//
// Two sources, mirroring the sheet:
//   • readings — surfaceReadingData[surface] when present, else the Lexicon's deinflected, forward-
//     projected lemma readings (so an inflected surface exposes every admitted lemma's reading).
//   • entries  — Lexicon.lookupLexeme(lemma, reading) so a homographic kanji resolves to the entry
//     whose kana form is exactly that reading; a store.lookup fallback covers a nil Lexicon.
// Order follows the readings source; the entry attached to a reading may be nil when nothing matched.
nonisolated enum ReadingVariants {
    // One reading of a surface plus the dictionary context the switcher needs to follow it.
    struct Variant: Equatable {
        let reading: String
        let lemma: String
        let chain: [String]
        let entry: DictionaryEntry?
    }

    // Ordered, de-duplicated variants for the surface. Empty when no reading source resolves.
    static func variants(
        surface: String,
        lexicon: Lexicon?,
        store: DictionaryStore?,
        segmenter: (any TextSegmenting)?,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> [Variant] {
        let readings = orderedReadings(
            surface: surface,
            lexicon: lexicon,
            segmenter: segmenter,
            surfaceReadingData: surfaceReadingData
        )
        guard readings.isEmpty == false else { return [] }

        let infoByReading = lemmaInfoByReading(
            surface: surface,
            lexicon: lexicon,
            store: store,
            surfaceReadingData: surfaceReadingData
        )
        return readings.map { reading in
            let info = infoByReading[reading]
            return Variant(
                reading: reading,
                lemma: info?.lemma ?? surface,
                chain: info?.chain ?? [],
                entry: info?.entry
            )
        }
    }

    // The distinct readings to display, in cycle order — mirrors the sheet's sheetReadingsProvider.
    // Prefers the in-memory surface map (covers base forms and kana surfaces with no SQL), then the
    // Lexicon's forward-projected lemma readings for inflected forms, then a segmenter-lemma fallback
    // when no Lexicon is wired (other call sites). Returns [] when nothing resolves.
    private static func orderedReadings(
        surface: String,
        lexicon: Lexicon?,
        segmenter: (any TextSegmenting)?,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> [String] {
        if let data = surfaceReadingData[surface], data.readings.isEmpty == false {
            return data.readings
        }
        guard let lexicon else {
            if let lemma = segmenter?.preferredLemma(for: surface),
               let lemmaData = surfaceReadingData[lemma], lemmaData.readings.isEmpty == false {
                return lemmaData.readings
            }
            return []
        }
        var combined: [String] = []
        var seen: Set<String> = []
        for group in lexicon.surfaceReadingsByLemma(surface: surface) {
            for reading in group.surfaceReadings where seen.insert(reading).inserted {
                combined.append(reading)
            }
        }
        return combined
    }

    // Per-reading (lemma, chain, entry) — mirrors the sheet's sheetLemmaInfoByReadingProvider, with a
    // store-only fallback added so the map still resolves entries when no Lexicon is wired. The entry
    // is the one whose kana form matches the reading exactly, disambiguating homographs (様 さま/よう,
    // 抱く いだく/だく/うだく); it may be nil for a projected inflected reading that matches no kana form.
    private static func lemmaInfoByReading(
        surface: String,
        lexicon: Lexicon?,
        store: DictionaryStore?,
        surfaceReadingData: SurfaceReadingDataMap
    ) -> [String: (lemma: String, chain: [String], entry: DictionaryEntry?)] {
        guard surface.isEmpty == false else { return [:] }
        var byReading: [String: (lemma: String, chain: [String], entry: DictionaryEntry?)] = [:]

        // Path 1: Lexicon-projected lemma readings, each resolved to its exact-kana entry.
        if let lexicon {
            for group in lexicon.surfaceReadingsByLemma(surface: surface) {
                let lemmaMode: LookupMode = ScriptClassifier.containsKanji(group.lemma) ? .kanjiAndKana : .kanaOnly
                let lemmaFallback = (try? store?.lookup(surface: group.lemma, mode: lemmaMode))?.first
                for reading in group.surfaceReadings where byReading[reading] == nil {
                    let perReadingEntry = lexicon.lookupLexeme(group.lemma, reading).first
                    byReading[reading] = (lemma: group.lemma, chain: group.chain, entry: perReadingEntry ?? lemmaFallback)
                }
            }
        }

        // Path 2: in-memory surface readings (kana surfaces, base forms) not covered by Path 1.
        if let data = surfaceReadingData[surface], data.readings.isEmpty == false {
            for reading in data.readings where byReading[reading] == nil {
                let entry = lexicon?.lookupLexeme(surface, reading).first ?? entryMatchingReading(surface, reading, store: store)
                byReading[reading] = (lemma: surface, chain: [], entry: entry)
            }
        }
        return byReading
    }

    // Store-only entry resolution: the entry under `lemma` whose kana form equals `reading`. Used as
    // the no-Lexicon fallback so homographs still split correctly off the bundled dictionary alone.
    private static func entryMatchingReading(_ lemma: String, _ reading: String, store: DictionaryStore?) -> DictionaryEntry? {
        guard let store else { return nil }
        let mode: LookupMode = ScriptClassifier.containsKanji(lemma) ? .kanjiAndKana : .kanaOnly
        let entries = (try? store.lookup(surface: lemma, mode: mode)) ?? []
        return entries.first { $0.kanaForms.contains { $0.text == reading } }
    }
}
