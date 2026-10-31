import Foundation

// Where Guided Sing is in a line: the song plays it, then the singer repeats it while the mic
// listens, then the line's results wait for a retry or the next line.
enum SingGuidedPhase: Equatable {
    case listening
    case yourTurn
    case review
}
