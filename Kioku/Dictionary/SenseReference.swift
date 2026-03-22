import Foundation

// The two JMdict sense-reference variants: cross-reference (xref) or antonym (ant).
public enum SenseReferenceKind: String, Equatable {
    case xref
    case ant
}

// A sense-level cross-reference or antonym link from JMdict xref/ant elements.
public struct SenseReference: Equatable {
    // Zero-based position of the owning sense within its entry, matching senses.order_index.
    public let senseOrderIndex: Int
    // Whether this link is a cross-reference or an antonym.
    public let type: SenseReferenceKind
    // Target expression; may be a bare word, "word・reading", or "word・reading・senseNum".
    public let target: String

    public init(senseOrderIndex: Int, type: SenseReferenceKind, target: String) {
        // Stores one JMdict xref/ant record linking a sense to a related or opposing entry.
        self.senseOrderIndex = senseOrderIndex
        self.type = type
        self.target = target
    }
}
