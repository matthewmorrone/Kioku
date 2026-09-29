import Foundation

// Carries a value the compiler can't prove Sendable across a Sendable boundary (a background
// dispatch, a persist queue). Each use site states why its value is actually safe to share:
// UserDefaults is documented thread-safe; the segment-list lemma resolvers only read from the
// nonisolated Segmenter.
nonisolated final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(value: T) { self.value = value }
}
