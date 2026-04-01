import Foundation

nonisolated public enum LookupMode {
    case kanaOnly
    case kanjiAndKana

    public var allowsKanjiMatching: Bool {
        self == .kanjiAndKana
    }
}
