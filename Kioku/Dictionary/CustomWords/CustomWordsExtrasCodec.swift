import Foundation

// Reads and writes the Custom Words list as an extras.json file, the same format
// Resources/generate_db.py builds the dictionary from (load_extra_entries documents the shape), so an
// exported list can be dropped into the repo and an extras.json imported into the app. Accepts every
// shorthand the builder accepts: a bare list or { entries }, string-or-array forms and glosses,
// `{ text }` objects, the top-level `gloss` shorthand, and `sameAs` spellings of an existing entry.
nonisolated enum CustomWordsExtrasCodec {
    // The list as a pretty-printed extras.json, keys sorted so exports diff cleanly.
    static func encode(_ words: [CustomWord]) throws -> Data {
        let entries: [[String: Any]] = words.map { word in
            var entry: [String: Any] = [:]
            if word.kanji.isEmpty == false { entry["kanji"] = word.kanji }
            if word.kana.isEmpty == false { entry["kana"] = word.kana }
            if let sameAs = word.sameAsEntSeq {
                entry["sameAs"] = sameAs
                return entry
            }
            if let entSeq = word.entSeq { entry["ent_seq"] = entSeq }
            entry["sense"] = word.senses.map { sense -> [String: Any] in
                var object: [String: Any] = ["gloss": sense.glosses]
                if sense.partOfSpeech.isEmpty == false { object["partOfSpeech"] = sense.partOfSpeech }
                if sense.misc.isEmpty == false { object["misc"] = sense.misc }
                return object
            }
            return entry
        }
        return try JSONSerialization.data(withJSONObject: ["entries": entries], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // The words in an extras.json file, as new CustomWords (fresh ids, no default key).
    static func decode(_ data: Data) throws -> [CustomWord] {
        let root = try JSONSerialization.jsonObject(with: data)
        let rawEntries: [Any]
        if let list = root as? [Any] {
            rawEntries = list
        } else if let object = root as? [String: Any] {
            rawEntries = object["entries"] as? [Any] ?? []
        } else {
            throw CustomWordsExtrasDecodeError.notExtrasJSON
        }
        return try rawEntries.enumerated().map { index, raw in
            guard let entry = raw as? [String: Any] else { throw CustomWordsExtrasDecodeError.entryNotObject(index) }
            return word(from: entry)
        }
    }

    // One entry object as a CustomWord.
    private static func word(from entry: [String: Any]) -> CustomWord {
        let sameAs = (entry["sameAs"] as? NSNumber)?.int64Value
        var senses: [CustomWordSense] = []
        if sameAs == nil {
            if let shorthand = entry["gloss"] {
                senses = [CustomWordSense(partOfSpeech: [], misc: [], glosses: texts(shorthand))]
            } else if let sense = entry["sense"] as? String {
                senses = [CustomWordSense(partOfSpeech: [], misc: [], glosses: [sense])]
            } else if let sense = entry["sense"] {
                let objects = (sense as? [Any]) ?? [sense]
                senses = objects.compactMap { $0 as? [String: Any] }.map { object in
                    CustomWordSense(
                        partOfSpeech: texts(object["partOfSpeech"]),
                        misc: texts(object["misc"]),
                        glosses: texts(object["gloss"])
                    )
                }
            }
        }
        return CustomWord(
            id: UUID(),
            entSeq: sameAs == nil ? (entry["ent_seq"] as? NSNumber)?.int64Value : nil,
            sameAsEntSeq: sameAs,
            kanji: texts(entry["kanji"]),
            kana: texts(entry["kana"]),
            senses: senses,
            defaultKey: nil
        )
    }

    // A string, a `{ text }` object, or an array of either, as plain strings.
    private static func texts(_ value: Any?) -> [String] {
        let items = (value as? [Any]) ?? (value.map { [$0] } ?? [])
        return items.compactMap { item in
            if let string = item as? String { return string }
            return (item as? [String: Any])?["text"] as? String
        }
    }
}
