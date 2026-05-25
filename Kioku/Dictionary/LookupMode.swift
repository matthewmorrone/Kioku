import Foundation

nonisolated public enum LookupMode: Sendable {
    case kanaOnly
    case kanjiAndKana

    public var allowsKanjiMatching: Bool {
        self == .kanjiAndKana
    }
}
