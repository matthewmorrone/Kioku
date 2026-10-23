import Foundation

// One preference value inside a backup. UserDefaults holds only property-list scalars, and a
// backup needs them typed so a restore writes a Bool back as a Bool and a Double as a Double.
nonisolated enum AppBackupSettingValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringList([String])
    case intList([Int])

    // Reads a stored UserDefaults object as a typed value; nil for anything that is not a scalar.
    init?(defaultsObject object: Any) {
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        } else if let text = object as? String {
            self = .string(text)
        } else if let ints = object as? [Int], ints.isEmpty == false {
            self = .intList(ints)
        } else if let texts = object as? [String] {
            self = .stringList(texts)
        } else {
            return nil
        }
    }

    // Decodes the bare JSON scalar, trying the narrowest type first so 1 stays an Int and true a Bool.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Int].self), value.isEmpty == false {
            self = .intList(value)
        } else {
            self = .stringList(try container.decode([String].self))
        }
    }

    // Encodes as the bare JSON scalar.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .stringList(let value): try container.encode(value)
        case .intList(let value): try container.encode(value)
        }
    }

    // The value as a UserDefaults-storable object.
    var defaultsObject: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .stringList(let value): return value
        case .intList(let value): return value
        }
    }
}
