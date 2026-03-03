import Foundation

public final class DictionaryTrie {

    private final class Node {
        var children: [UInt16: Node] = [:]
        var isTerminal: Bool = false
    }

    private let root = Node()
    public private(set) var surfaceCount: Int = 0
    private(set) var maxSurfaceLength: Int = 0

    public init() {}

    public convenience init(surfaces: [String]) {
        self.init()
        build(from: surfaces)
    }

    public func build(from surfaces: [String]) {
        root.children.removeAll(keepingCapacity: false)
        root.isTerminal = false
        surfaceCount = 0
        maxSurfaceLength = 0

        for surface in surfaces {
            insert(surface)
        }
    }

    public func insert(_ surface: String) {
        let normalized = surface.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return }

        var node = root
        var length = 0

        for unit in normalized.utf16 {
            length += 1
            if let next = node.children[unit] {
                node = next
            } else {
                let next = Node()
                node.children[unit] = next
                node = next
            }
        }

        if !node.isTerminal {
            node.isTerminal = true
            surfaceCount += 1
            if length > maxSurfaceLength {
                maxSurfaceLength = length
            }
        }
    }

    public func contains(_ surface: String) -> Bool {
        let normalized = surface.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return false }

        var node = root
        for unit in normalized.utf16 {
            guard let next = node.children[unit] else {
                return false
            }
            node = next
        }

        return node.isTerminal
    }

    public func hasPrefix(_ prefix: String) -> Bool {
        let normalized = prefix.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return false }

        var node = root
        for unit in normalized.utf16 {
            guard let next = node.children[unit] else {
                return false
            }
            node = next
        }

        return true
    }
}
