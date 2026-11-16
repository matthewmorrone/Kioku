import Foundation

// Pulls the 11-character video id out of whatever the user pasted: a watch, share, shorts, embed or
// music.youtube.com link, or the bare id itself. One parser so the note, the player and the audio
// fetch all agree on which video a link means.
enum YouTubeVideoID {
    // Returns the video id for a pasted link or bare id, or nil when it isn't recognisably YouTube.
    static func parse(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if isValid(trimmed) { return trimmed }

        // Links pasted without a scheme ("youtu.be/…") still parse once one is added.
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let host = components.host?.lowercased() else { return nil }

        let segments = components.path.split(separator: "/").map(String.init)
        if host == "youtu.be" {
            return segments.first.flatMap { isValid($0) ? $0 : nil }
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }

        if let queryID = components.queryItems?.first(where: { $0.name == "v" })?.value, isValid(queryID) {
            return queryID
        }
        // /shorts/<id>, /embed/<id>, /live/<id>, /v/<id>
        if segments.count >= 2, ["shorts", "embed", "live", "v"].contains(segments[0]), isValid(segments[1]) {
            return segments[1]
        }
        return nil
    }

    // Whether `candidate` has the shape of a video id: 11 characters of letters, digits, '-' and '_'.
    static func isValid(_ candidate: String) -> Bool {
        guard candidate.count == 11 else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
