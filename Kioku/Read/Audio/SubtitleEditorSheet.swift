import SwiftUI
import UIKit

// Presents a raw SRT text editor for the subtitle cues attached to a note.
// On save the text is re-parsed and the updated cues are persisted via NotesAudioStore.
// Includes timing shift and normalization tools for adjusting alignment results.
struct SubtitleEditorSheet: View {
    var attachmentID: UUID
    var initialCues: [SubtitleCue]
    var noteText: String
    // Called with the newly parsed cues after a successful save.
    var onSave: ([SubtitleCue]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var srtText = ""
    @State private var parseError = ""
    @State private var exportDocument = SRTDocument(text: "")
    @State private var isShowingExporter = false
    @State private var timeStepSeconds: Double = 0.5
    @State private var editorSelection = NSRange(location: 0, length: 0)

    // Parses the current editor text into cues for live mismatch detection.
    private var liveCues: [SubtitleCue] {
        SubtitleParser.parse(srtText)
    }

    // Resolves highlight ranges against note text for the current editor cues.
    private var liveHighlightRanges: [NSRange?] {
        SubtitleParser.resolveHighlightRanges(for: liveCues, in: noteText)
    }

    // Number of text cues whose content doesn't match the corresponding note line.
    private var mismatchCount: Int {
        liveCues.enumerated().filter { index, cue in
            guard SubtitleParser.isNonSpeechCue(cue.text) == false else { return false }
            guard index < liveHighlightRanges.count,
                  let range = liveHighlightRanges[index],
                  let swiftRange = Range(range, in: noteText) else { return false }
            return String(noteText[swiftRange]) != cue.text
        }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StableTextEditor(text: $srtText, selectedRange: $editorSelection)
                    .padding(.horizontal, 8)

                Divider()
                subtitleToolsBar
            }
            .navigationTitle("Edit Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = srtText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(srtText.isEmpty)

                    Button {
                        exportDocument = SRTDocument(text: srtText)
                        isShowingExporter = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(srtText.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { performSave() }
                }
            }
            .alert("Parse Error", isPresented: parseErrorPresented) {
                Button("OK", role: .cancel) { parseError = "" }
            } message: {
                Text(parseError)
            }
        }
        .onAppear {
            srtText = NotesAudioStore.shared.loadSRT(for: attachmentID) ?? SubtitleParser.formatSRT(from: initialCues)
        }
        .fileExporter(
            isPresented: $isShowingExporter,
            document: exportDocument,
            contentType: .subripText,
            defaultFilename: NotesAudioStore.shared.preferredSubtitleExportFilename(for: attachmentID)
        ) { result in
            if case .failure(let error) = result {
                parseError = error.localizedDescription
            }
        }
    }

    // Bottom toolbar with timing shift and normalization controls.
    private var subtitleToolsBar: some View {
        HStack(spacing: 8) {
            // Shift timestamps backward.
            Button {
                shiftTimes(by: -timeStepSeconds)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.bordered)

            // Configurable time step amount.
            Menu {
                ForEach(timeStepOptions, id: \.self) { step in
                    Button(formatStep(step)) {
                        timeStepSeconds = step
                    }
                }
            } label: {
                Text(formatStep(timeStepSeconds))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 44)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(.tertiarySystemFill)))
            }

            // Shift timestamps forward.
            Button {
                shiftTimes(by: timeStepSeconds)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.bordered)

            Spacer()

            // Normalize timing: extend cues to fill gaps, insert ♪ for long gaps.
            Button {
                normalizeTiming()
            } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)

            // Match cue text to note text where they differ.
            if mismatchCount > 0 {
                Button {
                    normalizeCueText()
                } label: {
                    Label("\(mismatchCount)", systemImage: "text.badge.checkmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var timeStepOptions: [Double] {
        [0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0]
    }

    // Formats a time step value for display (e.g. 0.5 → "0.5s").
    private func formatStep(_ seconds: Double) -> String {
        if seconds == Double(Int(seconds)) {
            return "\(Int(seconds))s"
        }
        return "\(String(format: "%g", seconds))s"
    }

    // Returns the set of cue indices whose SRT blocks overlap the current editor selection.
    // When there's no selection (cursor only), returns all indices.
    private func selectedCueIndices() -> Set<Int> {
        let cues = liveCues
        guard editorSelection.length > 0 else {
            return Set(cues.indices)
        }

        // Build the SRT and find each cue block's range in the text.
        var selected = Set<Int>()
        let formatted = SubtitleParser.formatSRT(from: cues)
        let blocks = formatted.components(separatedBy: "\n\n")
        var offset = 0
        for (i, block) in blocks.enumerated() {
            let blockRange = NSRange(location: offset, length: block.utf16.count)
            if NSIntersectionRange(blockRange, editorSelection).length > 0 {
                selected.insert(i)
            }
            // +2 for the "\n\n" separator.
            offset += block.utf16.count + (i < blocks.count - 1 ? 2 : 0)
        }
        return selected
    }

    // Shifts timestamps for cues within the editor selection by the given offset.
    // When nothing is selected (cursor only), shifts all cues.
    private func shiftTimes(by offsetSeconds: Double) {
        var cues = liveCues
        guard cues.isEmpty == false else { return }
        let offsetMs = Int(offsetSeconds * 1000)
        let affected = selectedCueIndices()
        cues = cues.enumerated().map { i, cue in
            guard affected.contains(i) else { return cue }
            return SubtitleCue(
                index: cue.index,
                startMs: max(0, cue.startMs + offsetMs),
                endMs: max(0, cue.endMs + offsetMs),
                text: cue.text
            )
        }
        srtText = SubtitleParser.formatSRT(from: cues)
    }

    // Normalizes timing: extends each cue's end to meet the next cue's start (filling small gaps),
    // and inserts ♪ cues for instrumental gaps longer than the threshold.
    private func normalizeTiming() {
        let cues = liveCues
        guard cues.isEmpty == false else { return }
        let gapThreshold = 10_000 // ms — gaps longer than this get a ♪ cue

        var normalized: [SubtitleCue] = []

        // Insert ♪ before first cue if the leading gap is large.
        if let first = cues.first, first.startMs > gapThreshold {
            normalized.append(SubtitleCue(index: 0, startMs: 0, endMs: first.startMs, text: "♪"))
        }

        for (i, cue) in cues.enumerated() {
            var adjusted = cue

            // Extend first cue backward to 0 if the leading gap is small (no ♪ inserted).
            if i == 0 && cue.startMs > 0 && cue.startMs <= gapThreshold {
                adjusted = SubtitleCue(
                    index: adjusted.index,
                    startMs: 0,
                    endMs: adjusted.endMs,
                    text: adjusted.text
                )
            }
            // Small gap before this cue — pull its start back to meet the previous cue's end.
            if let prev = normalized.last, SubtitleParser.isNonSpeechCue(prev.text) == false {
                let gap = adjusted.startMs - prev.endMs
                if gap > 0 && gap <= gapThreshold {
                    adjusted = SubtitleCue(
                        index: adjusted.index,
                        startMs: prev.endMs,
                        endMs: adjusted.endMs,
                        text: adjusted.text
                    )
                }
            }
            normalized.append(adjusted)

            // Insert ♪ cue for large gaps.
            if i + 1 < cues.count {
                let gapStart = adjusted.endMs
                let gapEnd = cues[i + 1].startMs
                if gapEnd - gapStart > gapThreshold {
                    normalized.append(SubtitleCue(
                        index: 0,
                        startMs: gapStart,
                        endMs: gapEnd,
                        text: "♪"
                    ))
                }
            }
        }

        // Re-index sequentially.
        for i in normalized.indices {
            normalized[i] = SubtitleCue(
                index: i + 1,
                startMs: normalized[i].startMs,
                endMs: normalized[i].endMs,
                text: normalized[i].text
            )
        }

        srtText = SubtitleParser.formatSRT(from: normalized)
    }

    // Replaces each mismatched cue's text with the corresponding note text, preserving timestamps.
    private func normalizeCueText() {
        var cues = liveCues
        let ranges = liveHighlightRanges
        for index in cues.indices {
            guard SubtitleParser.isNonSpeechCue(cues[index].text) == false else { continue }
            guard index < ranges.count,
                  let range = ranges[index],
                  let swiftRange = Range(range, in: noteText) else { continue }
            let noteLineText = String(noteText[swiftRange])
            if noteLineText != cues[index].text {
                cues[index] = SubtitleCue(
                    index: cues[index].index,
                    startMs: cues[index].startMs,
                    endMs: cues[index].endMs,
                    text: noteLineText
                )
            }
        }
        srtText = SubtitleParser.formatSRT(from: cues)
    }

    // Binds the parse-error alert to whether there is currently a failure message.
    private var parseErrorPresented: Binding<Bool> {
        Binding(
            get: { parseError.isEmpty == false },
            set: { if !$0 { parseError = "" } }
        )
    }

    // Re-parses the edited SRT text, saves the cues to disk, and notifies the caller.
    private func performSave() {
        let newCues = SubtitleParser.parse(srtText)
        guard newCues.isEmpty == false else {
            parseError = "No valid subtitle cues found. Check the format and try again."
            return
        }

        do {
            try NotesAudioStore.shared.saveCues(newCues, attachmentID: attachmentID)
            _ = try NotesAudioStore.shared.saveSRT(
                srtText,
                attachmentID: attachmentID,
                preferredFilename: NotesAudioStore.shared.preferredSubtitleExportFilename(for: attachmentID)
            )
            onSave(newCues)
            dismiss()
        } catch {
            parseError = error.localizedDescription
        }
    }
}
