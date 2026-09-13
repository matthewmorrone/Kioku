import SwiftUI

// Timing export from the karaoke bar: the current cues as SRT (line timing, readable
// anywhere) and as the app's own cues JSON (line + per-mora checkpoints, lossless). Files are
// written to tmp on demand, named after the note's first line, and handed to ShareLink.
extension LyricsView {
    // Writes both files and returns their URLs; nil when there is nothing aligned yet.
    func timingExportURLs() -> (srt: URL, json: URL)? {
        guard cues.isEmpty == false else { return nil }
        let firstLine = noteText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.isEmpty == false } ?? "lyrics"
        let base = String(firstLine.replacingOccurrences(of: "/", with: "-").prefix(60))
        let dir = FileManager.default.temporaryDirectory
        let srtURL = dir.appendingPathComponent("\(base).srt")
        let jsonURL = dir.appendingPathComponent("\(base).cues.json")
        var srt = ""
        for (i, cue) in cues.enumerated() {
            srt += "\(i + 1)\n\(SubtitleTimecode.formatSRT(cue.startMs)) --> \(SubtitleTimecode.formatSRT(cue.endMs))\n\(cue.text)\n\n"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard (try? srt.write(to: srtURL, atomically: true, encoding: .utf8)) != nil,
              let json = try? encoder.encode(cues), (try? json.write(to: jsonURL, options: .atomic)) != nil else { return nil }
        return (srtURL, jsonURL)
    }

    // The bar's export control: a menu offering the two formats, disabled with no cues.
    func exportMenu() -> some View {
        Menu {
            if let urls = timingExportURLs() {
                ShareLink(item: urls.srt) { Label("SRT (lines)", systemImage: "doc.text") }
                ShareLink(item: urls.json) { Label("JSON (lines + word timing)", systemImage: "curlybraces") }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(cues.isEmpty ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background((cues.isEmpty ? Color.secondary : Color.accentColor).opacity(0.16))
                .clipShape(Capsule())
        }
        .disabled(cues.isEmpty)
        .accessibilityLabel("Export timing")
    }
}
