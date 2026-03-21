import Foundation

// Represents one BFS state consisting of a current surface and grammar label.
// Depth is excluded so the visited set detects cycles across paths of different lengths.
struct DeinflectionState: Hashable {
    let surface: String
    let grammar: String?
}
