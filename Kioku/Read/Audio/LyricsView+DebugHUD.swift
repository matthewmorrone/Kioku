import SwiftUI

// Karaoke diagnostics HUD helpers — the single-line status string that overlays the lyrics
// popup when Settings → Debug → "Karaoke HUD" is on, plus the cue-text neighbor preview
// used inside it. Split out of LyricsView.swift so the main file focuses on layout.
extension LyricsView {
    // Builds the live-state HUD shown at the top of the lyrics popup so the user can see what
    // the karaoke pipeline is doing. Kept terse — every field is one short token.
    var karaokeDebugHUDText: String {
        let cueIdx = controller.activeCueIndex ?? -1
        let activeCue: SubtitleCue? = (cueIdx >= 0 && cueIdx < cues.count) ? cues[cueIdx] : nil
        let lookupKey: Int? = activeCue?.index
        let cpCount = activeCue?.checkpoints.count ?? 0
        let totalKeys = cues.filter { $0.checkpoints.isEmpty == false }.count
        let overrideText: String = {
            guard let r = playbackHighlightRangeOverride else { return "nil" }
            return "[\(r.location),\(r.length)]"
        }()
        let highlightRangeText: String = {
            guard cueIdx >= 0, cueIdx < highlightRanges.count else { return "?" }
            guard let r = highlightRanges[cueIdx] else { return "nil" }
            return "[\(r.location),\(r.length)]"
        }()
        let cueLen: Int = {
            guard cueIdx >= 0, cueIdx < cues.count else { return 0 }
            return cues[cueIdx].text.utf16.count
        }()
        let t = controller.currentTimeMs
        let p0 = cueTextPreview(at: cueIdx - 1)
        let p1 = cueTextPreview(at: cueIdx)
        let p2 = cueTextPreview(at: cueIdx + 1)
        let p3 = cueTextPreview(at: cueIdx + 2)
        let neighborText = "[\(p0) | \(p1) | \(p2) | \(p3)]"
        return "g=\(granularity.rawValue) cue=\(cueIdx) key=\(lookupKey.map(String.init) ?? "-") cp=\(cpCount) total=\(totalKeys) hr=\(highlightRangeText) cueLen=\(cueLen) ovr=\(overrideText) t=\(t) \(neighborText)"
    }

    // Returns a short preview of the cue text at the given index for the HUD's neighbor strip.
    // Returns "-" when the index is out of range, and collapses internal newlines so a multi-
    // line cue still fits on one HUD line.
    func cueTextPreview(at index: Int) -> String {
        guard index >= 0, index < cues.count else { return "-" }
        let s = cues[index].text.replacingOccurrences(of: "\n", with: "/")
        return String(s.prefix(8))
    }
}
