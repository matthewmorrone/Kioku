import Foundation

// What Sing mode practises: the whole song, or the current line on a loop.
enum SingScope: String, CaseIterable {
    case song = "Song"
    case line = "Line"
}
