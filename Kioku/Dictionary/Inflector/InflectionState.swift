import Foundation

// Represents one BFS state consisting of a current surface and grammar label.
struct InflectionState: Hashable {
    let surface: String
    let grammar: String?
    let depth: Int
}
