import Foundation

// A single Word of the Day entry mirrored from the notification schedule into the App Group
// container so the widget process can read it. Compiled into BOTH the app and widget targets;
// it is plain Foundation with no app/widget dependencies so it can be unit tested directly.
nonisolated struct WordOfTheDayMirrorEntry: Codable, Equatable, Sendable {
    // When the corresponding notification is scheduled to fire. Drives both "most recent" selection
    // and the widget timeline (one timeline entry per fire date so the widget flips on schedule).
    let fireDate: Date
    let surface: String
    let kana: String?
    let meaning: String
    let entryID: Int64

    init(fireDate: Date, surface: String, kana: String?, meaning: String, entryID: Int64) {
        self.fireDate = fireDate
        self.surface = surface
        self.kana = kana
        self.meaning = meaning
        self.entryID = entryID
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
