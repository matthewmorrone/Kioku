import Foundation

nonisolated public struct TriePrefixHit {
    public let start: String.Index
    public let end: String.Index
    public let surface: String
    public let indices: [Int]

    public init(start: String.Index, end: String.Index, surface: String, indices: [Int]) {
        self.start = start
        self.end = end
        self.surface = surface
        self.indices = indices
    }
}
