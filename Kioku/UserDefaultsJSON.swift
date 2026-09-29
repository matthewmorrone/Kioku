import Foundation

// JSON-in-UserDefaults reads and writes for the stores that keep a Codable blob under one key.
// Failures are logged under the caller's feature instead of vanishing into `try?`: a blob that
// stops decoding otherwise looks exactly like "nothing saved yet".
nonisolated enum UserDefaultsJSON {
    // Decodes the value stored under `key`. nil when nothing is stored or the stored bytes don't
    // decode (the latter is logged).
    static func load<T: Decodable>(
        _ type: T.Type,
        forKey key: String,
        from defaults: UserDefaults = .standard,
        logAs feature: LogFeature
    ) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.error(feature, "\(key): stored value did not decode — \(error.localizedDescription)")
            return nil
        }
    }

    // Encodes `value` and stores it under `key`, skipping the write when the encoding is
    // byte-identical to what is already stored. Encoding failures are logged and leave the
    // stored value untouched.
    static func save<T: Encodable>(
        _ value: T,
        forKey key: String,
        to defaults: UserDefaults = .standard,
        logAs feature: LogFeature
    ) {
        do {
            let encoded = try JSONEncoder().encode(value)
            guard encoded != defaults.data(forKey: key) else { return }
            defaults.set(encoded, forKey: key)
        } catch {
            AppLog.error(feature, "\(key): could not encode value — \(error.localizedDescription)")
        }
    }
}
