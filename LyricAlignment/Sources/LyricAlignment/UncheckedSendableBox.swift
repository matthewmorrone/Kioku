// Wraps a non-Sendable value (here: whisper.cpp's OpaquePointer context) so it can cross
// a @Sendable closure boundary. Safe specifically because every use in this package hands
// the wrapped pointer into exactly one synchronous C call on the background queue, with no
// concurrent access — the pointer itself is never mutated or shared across threads at once.
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}
