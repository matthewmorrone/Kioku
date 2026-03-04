// Stores trie child links and terminal state for dictionary surface paths.
internal final class Node {
    var children: [Character: Node] = [:]
    var isTerminal: Bool = false
}
