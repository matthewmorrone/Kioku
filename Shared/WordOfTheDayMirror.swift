import Foundation

// One sense of a word: a friendly part-of-speech label plus its English glosses.
nonisolated struct WordOfTheDaySense: Codable, Equatable, Sendable {
    let partOfSpeech: String?
    let glosses: [String]
}

// An example sentence with its translation, shown on the larger widget sizes.
nonisolated struct WordOfTheDayExample: Codable, Equatable, Sendable {
    let japanese: String
    let english: String
}

// A single Word of the Day entry mirrored from the notification schedule into the App Group
// container so the widget process can read it. Compiled into BOTH the app and widget targets;
// it is plain Foundation with no app/widget dependencies so it can be unit tested directly.
nonisolated struct WordOfTheDayMirrorEntry: Codable, Equatable, Sendable {
    // When the corresponding notification is scheduled to fire. Drives both "most recent" selection
    // and the widget timeline (one timeline entry per fire date so the widget flips on schedule).
    let fireDate: Date
    let surface: String
    let kana: String?
    // The primary gloss — used by the notification body, the small widget, and the accessory slots.
    let meaning: String
    let entryID: Int64
    // Senses for the larger sizes: medium shows the first; large numbers two or three. Empty for
    // legacy entries (the small/accessory layouts fall back to `meaning`).
    let senses: [WordOfTheDaySense]
    // An example sentence, when the dictionary has one for this word.
    let example: WordOfTheDayExample?
    // JLPT level (5…1), shown as a small badge on the larger sizes.
    let jlpt: Int?

    init(fireDate: Date, surface: String, kana: String?, meaning: String, entryID: Int64,
         senses: [WordOfTheDaySense] = [], example: WordOfTheDayExample? = nil, jlpt: Int? = nil) {
        self.fireDate = fireDate
        self.surface = surface
        self.kana = kana
        self.meaning = meaning
        self.entryID = entryID
        self.senses = senses
        self.example = example
        self.jlpt = jlpt
    }

    // Custom decode so mirror data written before the rich fields existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fireDate = try c.decode(Date.self, forKey: .fireDate)
        surface = try c.decode(String.self, forKey: .surface)
        kana = try c.decodeIfPresent(String.self, forKey: .kana)
        meaning = try c.decode(String.self, forKey: .meaning)
        entryID = try c.decode(Int64.self, forKey: .entryID)
        senses = try c.decodeIfPresent([WordOfTheDaySense].self, forKey: .senses) ?? []
        example = try c.decodeIfPresent(WordOfTheDayExample.self, forKey: .example)
        jlpt = try c.decodeIfPresent(Int.self, forKey: .jlpt)
    }

    // The primary sense's glosses, guaranteed non-empty by falling back to the primary meaning.
    var displayGlosses: [String] {
        if let first = senses.first, first.glosses.isEmpty == false { return first.glosses }
        return [meaning]
    }

    // The primary sense's part of speech, for the medium layout.
    var primaryPartOfSpeech: String? {
        senses.first?.partOfSpeech
    }
}

// Read/write/clear helpers for the shared App Group store plus the pure selection and deep-link
// logic. The app writes the mirror whenever the WOTD schedule is (re)built and clears it when the
// feature is disabled; the widget only reads.
nonisolated enum WordOfTheDayMirror {
    // Must match the App Group declared in both targets' entitlements.
    static let appGroupID = "group.matthewmorrone.Kioku"
    private static let mirrorKey = "wordOfTheDay.mirror.v1"

    // The shared defaults suite. nil only if the App Group entitlement is missing/misconfigured.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Storage

    // Replaces the mirror with the given batch. Called by the app after (re)scheduling.
    static func write(_ entries: [WordOfTheDayMirrorEntry]) {
        guard let defaults = sharedDefaults else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: mirrorKey)
    }

    // Removes the mirror entirely. Called when WOTD is disabled or unauthorized so the widget
    // never shows a word the user is no longer receiving.
    static func clear() {
        sharedDefaults?.removeObject(forKey: mirrorKey)
    }

    // Loads the mirrored batch, or an empty array when nothing is stored / decoding fails.
    static func load() -> [WordOfTheDayMirrorEntry] {
        guard
            let defaults = sharedDefaults,
            let data = defaults.data(forKey: mirrorKey),
            let entries = try? JSONDecoder().decode([WordOfTheDayMirrorEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    // MARK: - Selection (pure)

    // The word from the most recent notification "sent" as of `now`: the entry with the greatest
    // fireDate that is not in the future. Returns nil when no entry has fired yet (or the mirror is
    // empty). Pure and side-effect free so the widget's display logic is unit testable.
    static func mostRecentEntry(in entries: [WordOfTheDayMirrorEntry], asOf now: Date) -> WordOfTheDayMirrorEntry? {
        entries
            .filter { $0.fireDate <= now }
            .max { $0.fireDate < $1.fireDate }
    }

    // The single word the widget should display: the most recent one already sent, or — when none
    // has fired yet — the soonest upcoming one. The fallback means a freshly enabled schedule shows
    // today's (or the next) word immediately instead of an empty prompt, since every scheduled fire
    // time is initially in the future.
    static func currentEntry(in entries: [WordOfTheDayMirrorEntry], asOf now: Date) -> WordOfTheDayMirrorEntry? {
        if let sent = mostRecentEntry(in: entries, asOf: now) {
            return sent
        }
        return entries
            .filter { $0.fireDate > now }
            .min { $0.fireDate < $1.fireDate }
    }

    // The most recently fired entries before `current`, newest first, up to `limit`. Drives the
    // large widget's "recent days" list. Excludes the entry matching `current` (same fire date) so
    // today's headline word isn't repeated in the list below it.
    static func recentEntries(
        in entries: [WordOfTheDayMirrorEntry],
        asOf now: Date,
        excluding current: WordOfTheDayMirrorEntry?,
        limit: Int
    ) -> [WordOfTheDayMirrorEntry] {
        entries
            .filter { $0.fireDate <= now && $0.fireDate != current?.fireDate }
            .sorted { $0.fireDate > $1.fireDate }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Deep link

    // Builds the widget tap URL, e.g. kioku://word?id=123&surface=勉強.
    static func deepLinkURL(entryID: Int64, surface: String) -> URL? {
        var components = URLComponents()
        components.scheme = "kioku"
        components.host = "word"
        components.queryItems = [
            URLQueryItem(name: "id", value: String(entryID)),
            URLQueryItem(name: "surface", value: surface),
        ]
        return components.url
    }

    // Parses a kioku://word?id=…&surface=… URL back into its components. Returns nil for any URL
    // that is not a well-formed word deep link. Surface is optional (the entry ID is sufficient to
    // navigate; surface is only a resolution hint).
    static func parseDeepLink(_ url: URL) -> (entryID: Int64, surface: String?)? {
        guard
            url.scheme == "kioku",
            url.host == "word",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        let items = components.queryItems ?? []
        guard
            let idString = items.first(where: { $0.name == "id" })?.value,
            let entryID = Int64(idString)
        else {
            return nil
        }
        let surface = items.first(where: { $0.name == "surface" })?.value
        return (entryID, surface)
    }
}
