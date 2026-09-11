import SwiftUI

// Hosts segment surface and merge boundary validation helpers for the read screen.
extension ReadView {

    // Filters out non-lexical segments so punctuation and whitespace never trigger popovers.
    func shouldIgnoreSegmentForDefinitionLookup(_ segmentText: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return segmentText.unicodeScalars.allSatisfy { ignoredScalars.contains($0) }
    }

    // Validates whether two adjacent segments can be merged without crossing punctuation or newline boundaries.
    func isMergeAllowed(between leftEdge: LatticeEdge, and rightEdge: LatticeEdge) -> Bool {
        guard leftEdge.end == rightEdge.start else {
            return false
        }

        guard isLexicalSurface(leftEdge.surface), isLexicalSurface(rightEdge.surface) else {
            return false
        }

        let boundaryCharacterIndex = leftEdge.end
        if boundaryCharacterIndex > document.text.startIndex {
            let previousCharacter = document.text[document.text.index(before: boundaryCharacterIndex)]
            if previousCharacter == "\n" || previousCharacter == "\r" {
                return false
            }
        }

        if boundaryCharacterIndex < document.text.endIndex {
            let nextCharacter = document.text[boundaryCharacterIndex]
            if nextCharacter == "\n" || nextCharacter == "\r" {
                return false
            }
        }

        return true
    }

    // Determines whether a segment surface includes lexical content rather than punctuation/whitespace only.
    func isLexicalSurface(_ surface: String) -> Bool {
        let ignoredScalars = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return surface.unicodeScalars.contains { ignoredScalars.contains($0) == false }
    }

    // Flashes a temporary red boundary marker in read mode when an illegal merge is attempted.
    func flashIllegalMergeBoundary(between leftEdge: LatticeEdge, and rightEdge: LatticeEdge) {
        let boundaryRange = NSRange(leftEdge.start..<rightEdge.start, in: document.text)
        guard boundaryRange.location != NSNotFound else {
            return
        }

        segmentSelection.illegalMergeBoundaryLocation = boundaryRange.location
        segmentSelection.illegalMergeFlashTask?.cancel()
        segmentSelection.illegalMergeFlashTask = Task {
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard Task.isCancelled == false else {
                return
            }

            await MainActor.run {
                segmentSelection.illegalMergeBoundaryLocation = nil
            }
        }
    }

}
