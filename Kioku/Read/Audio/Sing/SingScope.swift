import Foundation

// What Sing mode practises: the whole song, the current line on a loop, or Guided: line by
// line, the song singing each one before the singer repeats it unaccompanied.
enum SingScope: String, CaseIterable {
    case song = "Song"
    case line = "Line"
    case guided = "Guided"
}
