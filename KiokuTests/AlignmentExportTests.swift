import XCTest
@testable import Kioku

// Batch timing export: aligns every <title>.mp3 + <title>.txt pair under
// <App Documents>/timing-export/in with the app's real pipeline (WholeSongAlignment + the
// dictionary-backed romanizer, exactly what Re-align runs) and writes <title>.srt and
// <title>.cues.json to timing-export/out. Not a quality test: it exists so a folder of songs can
// be (re)timed on the device from the Mac without attaching each one to a note.
@MainActor
final class AlignmentExportTests: XCTestCase {
    // Aligns each pair in turn and writes both files; a song that fails is reported and skipped.
    func testExportTimingForDocumentsFolder() async throws {
        let docs = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let inDir = docs.appendingPathComponent("timing-export/in", isDirectory: true)
        let outDir = docs.appendingPathComponent("timing-export/out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let audio = ((try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mp3" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard audio.isEmpty == false else { throw XCTSkip("Nothing under Documents/timing-export/in") }

        let resources = try TestReadResources.shared()
        let romanizer = LyricRomanizer(
            segmenter: resources.segmenter,
            surfaceReadingData: SurfaceReadingDataMap(try resources.dictionaryStore.fetchSurfaceReadingData()),
            kanjiReadingFallback: KanjiReadingFallbackMap(try resources.dictionaryStore.fetchKanjiReadingFallbackMap())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var failures: [String] = []
        for audioURL in audio {
            let title = audioURL.deletingPathExtension().lastPathComponent
            let textURL = inDir.appendingPathComponent(title + ".txt")
            guard let lyrics = try? String(contentsOf: textURL, encoding: .utf8) else { failures.append("\(title): no .txt"); continue }
            let lines = lyrics.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false && SubtitleParser.isNonSpeechCue($0) == false }
            do {
                let cues = try await WholeSongAlignment.cues(
                    audioURL: audioURL,
                    lyrics: lines.joined(separator: "\n"),
                    romanize: romanizer.spans(for:)
                )
                var srt = ""
                for (i, cue) in cues.enumerated() {
                    srt += "\(i + 1)\n\(SubtitleTimecode.formatSRT(cue.startMs)) --> \(SubtitleTimecode.formatSRT(cue.endMs))\n\(cue.text)\n\n"
                }
                try srt.write(to: outDir.appendingPathComponent(title + ".srt"), atomically: true, encoding: .utf8)
                try encoder.encode(cues).write(to: outDir.appendingPathComponent(title + ".cues.json"), options: .atomic)
                print("[TimingExport] \(title): \(cues.count) cues")
            } catch {
                failures.append("\(title): \(error.localizedDescription)")
            }
        }
        print("[TimingExport] done — \(audio.count - failures.count)/\(audio.count) songs; failures: \(failures)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
