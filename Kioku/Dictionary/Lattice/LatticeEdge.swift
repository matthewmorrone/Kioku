import Foundation
import Combine

// Represents one directed edge in a segmentation lattice over source text.
struct LatticeEdge {
    let start: String.Index
    let end: String.Index
    let surface: String
    let lemma: String
}
