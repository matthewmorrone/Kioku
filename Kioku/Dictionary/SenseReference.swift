import Foundation

// A sense-level cross-reference or antonym link from JMdict xref/ant elements.
public struct SenseReference: Equatable {
    // Zero-based position of the owning sense within its entry, matching senses.order_index.
    public let senseOrderIndex: Int
    // "xref" for a cross-reference, "ant" for an antonym.
    public let type: String
    // Target expression; may be a bare word, "word・reading", or "word・reading・senseNum".
    public let target: String

    public init(senseOrderIndex: Int, type: String, target: String) {
        // Stores one JMdict xref/ant record linking a sense to a related or opposing entry.
        self.senseOrderIndex = senseOrderIndex
        self.type = type
        self.target = target
    }
}
