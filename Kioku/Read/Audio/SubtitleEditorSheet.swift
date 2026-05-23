import AVFoundation
import SwiftUI
import SwiftWhisperAlign
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
    @State private var isRetiming = false
    @State private var retimeProgressMessage = ""
    @State private var retimeError = ""
    @State private var retimeTask: Task<Void, Never>?
    @State private var pendingRetimedSRT: String?
    @State private var isValidating = false
    @State private var validationProgressMessage = ""
    @State private var validationResult: ValidationResult?
    @State private var validationError = ""
    @State private var validationTask: Task<Void, Never>?

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
            .alert("Re-time Failed", isPresented: retimeErrorPresented) {
                Button("OK", role: .cancel) { retimeError = "" }
            } message: {
                Text(retimeError)
            }
            .alert("Alignment Validation", isPresented: validationResultPresented) {
                Button("OK", role: .cancel) { validationResult = nil }
            } message: {
                if let result = validationResult {
                    Text("\(result.misses) of \(result.total) cues miss (\(result.percentage)%)")
                } else {
                    Text("")
                }
            }
            .alert("Validation Failed", isPresented: validationErrorPresented) {
                Button("OK", role: .cancel) { validationError = "" }
            } message: {
                Text(validationError)
            }
            .sheet(isPresented: retimeReviewPresented) {
                if let proposed = pendingRetimedSRT {
                    RetimeReviewSheet(
                        oldSRT: srtText,
                        newSRT: proposed,
                        onApply: {
                            srtText = proposed
                            pendingRetimedSRT = nil
                        },
                        onCancel: { pendingRetimedSRT = nil }
                    )
                }
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

            // Inline progress display when a long-running action is in flight. Mirrors the
            // status text the old separate buttons used to show, so the user still sees what's
            // happening without opening the menu. Tapping the running pill cancels the task.
            if isRetiming || isValidating {
                Button {
                    if isRetiming { retimeTask?.cancel() }
                    if isValidating { validationTask?.cancel() }
                } label: {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        let message = isRetiming ? retimeProgressMessage : validationProgressMessage
                        if message.isEmpty == false {
                            Text(message)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text("Cancel")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel \(isRetiming ? "alignment" : "validation")")
            }

            // Mismatch-fix shortcut stays surfaced when there's work to do (count + orange
            // tint signal urgency). Hidden when zero so the toolbar doesn't carry a permanent
            // no-op button. The same action also lives in the alignment menu for discoverability.
            if mismatchCount > 0 {
                Button {
                    normalizeCueText()
                } label: {
                    Label("\(mismatchCount)", systemImage: "text.badge.checkmark")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .accessibilityLabel("Sync \(mismatchCount) cue text mismatches to note")
            }

            // All alignment actions live behind one labeled menu instead of a row of opaque
            // icons. Labels say verb + source so the user doesn't have to guess: the two
            // forced-alignment actions are explicitly parallel ("Realign — using note text"
            // vs "Realign — using current cues") so the only thing differentiating them
            // reads as the only thing that's different. Sections group by cost and effect:
            // Realign is slow (Whisper); Adjust is fast (timing math + text edits); Check
            // is read-only.
            Menu {
                Section("Realign with audio (Whisper)") {
                    Button {
                        retimeTask = Task { await reconcileFromNote() }
                    } label: {
                        Label("Using note text — adds missing lines", systemImage: "doc.text.below.ecg")
                    }
                    .disabled(isRetiming || isValidating || noteText.isEmpty)

                    Button {
                        retimeTask = Task { await retimeFromAudio() }
                    } label: {
                        Label("Using current cues — keeps cue text", systemImage: "waveform.path")
                    }
                    .disabled(isRetiming || isValidating || srtText.isEmpty)
                }

                Section("Adjust without re-aligning") {
                    Button {
                        normalizeTiming()
                    } label: {
                        Label("Tidy gaps, insert ♪ for silences", systemImage: "waveform.badge.magnifyingglass")
                    }
                    .disabled(isRetiming || srtText.isEmpty)

                    if mismatchCount > 0 {
                        Button {
                            normalizeCueText()
                        } label: {
                            Label("Apply note text to \(mismatchCount) mismatch\(mismatchCount == 1 ? "" : "es")", systemImage: "text.badge.checkmark")
                        }
                    }
                }

                Section("Diagnose") {
                    Button {
                        validationTask = Task { await validateAlignment() }
                    } label: {
                        Label("Check accuracy against Whisper", systemImage: "checkmark.seal")
                    }
                    .disabled(isRetiming || isValidating || srtText.isEmpty)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Alignment actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var timeStepOptions: [Double] {
        [0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0]
    }

    // Result of an alignment-validation pass: how many cues had transcribed audio that
    // didn't match their text after normalization, out of the total non-music cues checked.
    struct ValidationResult {
        let total: Int
        let misses: Int
        var percentage: Int {
            guard total > 0 else { return 0 }
            return Int((Double(misses) / Double(total) * 100).rounded())
        }
    }

    // Runs free-form Whisper transcription over the audio and compares each cue's text to
    // the Whisper output covering its time range. Reports a miss percentage so the user
    // has a one-number signal for alignment quality. Doesn't change the SRT.
    @MainActor
    private func validateAlignment() async {
        defer {
            isValidating = false
            validationProgressMessage = ""
            validationTask = nil
        }

        guard let audioURL = NotesAudioStore.shared.audioURL(for: attachmentID) else {
            validationError = "No audio is attached to this note."
            return
        }

        let cues = liveCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        guard cues.isEmpty == false else {
            validationError = "No subtitle lines to validate."
            return
        }

        isValidating = true
        validationProgressMessage = "Preparing model…"

        let modelURL: URL
        do {
            if let existing = OnDeviceLyricAligner.bestAvailableModelURL() {
                modelURL = existing
            } else {
                modelURL = try await OnDeviceLyricAligner.downloadDefaultModel { message in
                    Task { @MainActor in validationProgressMessage = message }
                }
            }
        } catch {
            validationError = "Couldn't prepare the model: \(error.localizedDescription)"
            return
        }

        validationProgressMessage = "Transcribing audio…"

        let segments: [TranscriptionValidator.Segment]
        do {
            segments = try await TranscriptionValidator.transcribe(
                audioURL: audioURL,
                modelURL: modelURL,
                cancellationCheck: { Task.isCancelled }
            )
        } catch {
            if Task.isCancelled { return }
            validationError = "Validation failed: \(error.localizedDescription)"
            return
        }

        // For each cue, concatenate Whisper segments overlapping its time range, normalize
        // both sides (strip whitespace + ASCII/Japanese punctuation), and check equality.
        var misses = 0
        for cue in cues {
            let cueStart = Double(cue.startMs) / 1000.0
            let cueEnd = Double(cue.endMs) / 1000.0
            let overlappingText = segments
                .filter { $0.end > cueStart && $0.start < cueEnd }
                .map(\.text)
                .joined()
            let cueNorm = Self.normalizeForCompare(cue.text)
            let asrNorm = Self.normalizeForCompare(overlappingText)
            if cueNorm.isEmpty == false, asrNorm.contains(cueNorm) || cueNorm.contains(asrNorm) {
                continue
            }
            if cueNorm == asrNorm { continue }
            misses += 1
        }

        validationResult = ValidationResult(total: cues.count, misses: misses)
    }

    // Strips whitespace and common punctuation so trivial differences (line breaks,
    // commas, the difference between 「」 and 『』, etc.) don't count as misses.
    private static func normalizeForCompare(_ s: String) -> String {
        let punctuation: Set<Character> = [
            " ", "\t", "\n", "\r", "　",
            ".", ",", "!", "?", ";", ":", "-", "—", "…",
            "。", "、", "！", "？", "・", "「", "」", "『", "』",
            "(", ")", "（", "）", "[", "]", "{", "}", "／", "/", "～", "~"
        ]
        return String(s.filter { !punctuation.contains($0) })
    }

    // Re-runs forced alignment on the audio attached to this note, using the existing cue
    // text as the script. Cue text is preserved verbatim; timings are recomputed by Whisper.
    // After alignment, audio gaps without speech are scanned with the same NonSpeechDetector
    // the aligner uses, and gaps with sustained non-silent audio are inserted as ♪ cues.
    @MainActor
    private func retimeFromAudio() async {
        // Pull text-only lines out of the current SRT so we can hand them to the aligner.
        // Existing ♪ cues are dropped — they aren't lyrics to align, and we'll re-derive
        // music markers from the audio after the speech alignment completes.
        let speechCues = liveCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
        let lines = speechCues.map(\.text).filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        await runAlignment(lines: lines, sourceLabel: "subtitle lines")
    }

    // Reconcile: anchored forced alignment using the note text as the authoritative script.
    // Where the SRT already has a cue whose text matches a note line, that cue's timings
    // are kept as fixed anchors. The aligner is only invoked on the audio windows between
    // anchors, with each window's expected lines as its script. This bounds drift: errors
    // can't cascade past an anchor because each window is independently aligned over a
    // short clip with a small token budget. Surfaces missing lines (they get aligned in
    // the gaps), adjusts timings (each gap's lines get fresh times), and never drops a
    // line — if a gap window is too small for its line count, lines are uniformly
    // distributed across the window as a force-fit fallback so the user can adjust by
    // hand and re-run. Degenerates gracefully: if no cues match (empty or all-mismatched
    // SRT), the entire audio becomes one gap and the action behaves like a full-song
    // forced alignment with the note text.
    @MainActor
    private func reconcileFromNote() async {
        defer {
            isRetiming = false
            retimeProgressMessage = ""
            retimeTask = nil
        }

        guard let audioURL = NotesAudioStore.shared.audioURL(for: attachmentID) else {
            retimeError = "No audio is attached to this note."
            return
        }

        let noteLines = noteText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && SubtitleParser.isNonSpeechCue($0) == false }
        guard noteLines.isEmpty == false else {
            retimeError = "No note lines to align."
            return
        }

        let existingCues = liveCues
        let musicCues = existingCues.filter { SubtitleParser.isNonSpeechCue($0.text) }
        let speechCues = existingCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }

        // Pure-logic steps (matching, gap construction, merging) live in
        // SubtitleReconciliation so they're unit-testable against docs/INVARIANTS.md.
        // This function keeps only the I/O bits — audio duration, slicing, aligner
        // invocation, and @State updates.
        let anchors = SubtitleReconciliation.matchAnchors(speechCues: speechCues, noteLines: noteLines)

        isRetiming = true
        retimeProgressMessage = "Measuring audio…"

        let audioDuration = await Self.audioDurationSeconds(for: audioURL) ?? 0
        guard audioDuration > 0 else {
            retimeError = "Couldn't read audio duration."
            return
        }

        let gaps = SubtitleReconciliation.buildGapWindows(
            anchors: anchors,
            noteLines: noteLines,
            audioDurationSeconds: audioDuration
        )

        if gaps.isEmpty {
            retimeError = "Every note line already has a matching cue — nothing to reconcile."
            return
        }

        // Prep model (downloaded if needed). Shared by all gaps in this run.
        retimeProgressMessage = "Preparing model…"
        let modelURL: URL
        do {
            if let existing = OnDeviceLyricAligner.bestAvailableModelURL() {
                modelURL = existing
            } else {
                modelURL = try await OnDeviceLyricAligner.downloadDefaultModel { message in
                    Task { @MainActor in retimeProgressMessage = message }
                }
            }
        } catch {
            retimeError = "Couldn't prepare the alignment model: \(error.localizedDescription)"
            return
        }

        var newCues: [SubtitleCue] = []
        let runStartedAt = Date()

        for (gapIdx, gap) in gaps.enumerated() {
            if Task.isCancelled { return }
            let elapsed = Int(Date().timeIntervalSince(runStartedAt))
            retimeProgressMessage = "Aligning gap \(gapIdx + 1)/\(gaps.count) · \(gap.lines.count) line\(gap.lines.count == 1 ? "" : "s") · \(elapsed)s"

            let sliceURL: URL
            do {
                sliceURL = try await Self.sliceAudio(audioURL: audioURL, from: gap.audioStart, to: gap.audioEnd)
            } catch {
                retimeError = "Couldn't slice audio for gap \(gapIdx + 1): \(error.localizedDescription)"
                return
            }
            defer { try? FileManager.default.removeItem(at: sliceURL) }

            let lyrics = gap.lines.joined(separator: "\n")
            let alignedCues: [SubtitleCue]
            do {
                let srt = try await OnDeviceLyricAligner.align(
                    audioURL: sliceURL,
                    lyrics: lyrics,
                    modelURL: modelURL,
                    cancellationCheck: { Task.isCancelled }
                )
                alignedCues = SubtitleParser.parse(srt)
            } catch {
                if Task.isCancelled { return }
                // Per the user's "do NOT drop lines" rule: an aligner failure on one gap
                // falls back to uniform distribution rather than abandoning the run.
                // The user can re-run reconcile after editing surrounding anchors to
                // get a real alignment for this stretch.
                print("[Reconcile] gap \(gapIdx + 1) alignment failed (\(error.localizedDescription)); force-fitting")
                alignedCues = []
            }

            let gapSpeechCues = alignedCues.filter { SubtitleParser.isNonSpeechCue($0.text) == false }
            let gapMusicCues = alignedCues.filter { SubtitleParser.isNonSpeechCue($0.text) }
            let speechToUse: [SubtitleCue]
            if gapSpeechCues.count == gap.lines.count {
                // Aligner returned the expected line count — trust its timings.
                speechToUse = gapSpeechCues
            } else {
                // Force-fit: uniformly distribute the expected lines across the gap's
                // window so every note line lands somewhere reasonable. Discards the
                // aligner's partial output rather than mixing partial-good with synthetic
                // — that mix tends to produce overlapping cues that confuse the user
                // worse than honest uniform spacing.
                speechToUse = SubtitleReconciliation.uniformDistribute(
                    lines: gap.lines,
                    windowStartMs: 0,
                    windowEndMs: Int((gap.audioEnd - gap.audioStart) * 1000)
                )
            }

            // Offset gap-local times to absolute audio times before merging.
            let offsetMs = Int(gap.audioStart * 1000)
            let absoluteCues = (speechToUse + gapMusicCues).map { cue -> SubtitleCue in
                var copy = cue
                copy.startMs += offsetMs
                copy.endMs += offsetMs
                return copy
            }
            newCues.append(contentsOf: absoluteCues)
        }

        // Merge via the pure helper so the contract (anchors preserved, music preserved,
        // consumed anchors dropped) is the same one tested by SubtitleReconciliationTests.
        let consumedAnchorIndices: Set<Int> = Set(gaps.compactMap { $0.consumedAnchorIndex })
        let merged = SubtitleReconciliation.mergeReconciledCues(
            anchors: anchors,
            consumedAnchorIndices: consumedAnchorIndices,
            musicCues: musicCues,
            newGapCues: newCues
        )

        pendingRetimedSRT = SubtitleParser.formatSRT(from: merged)
    }

    // Reads the duration of an audio file via AVAsset's async loader. nil when the load
    // fails or the asset has no audio tracks — callers fail the reconcile gracefully.
    private static func audioDurationSeconds(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            return nil
        }
    }

    // Extracts an audio range to a temp .m4a via AVAssetExportSession. The exported file
    // lives in /tmp and is cleaned up by the caller's defer block. Used to feed the
    // forced aligner a small clip per gap so it can run cleanly against just that window
    // without re-encountering the audio it has already anchored.
    private static func sliceAudio(audioURL: URL, from: Double, to: Double) async throws -> URL {
        let asset = AVURLAsset(url: audioURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "Kioku.Reconcile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't create exporter for audio slice."]
            )
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("kioku-reconcile-\(UUID().uuidString).m4a")
        exporter.outputURL = tempURL
        exporter.outputFileType = .m4a
        let timescale: CMTimeScale = 1000
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: from, preferredTimescale: timescale),
            end: CMTime(seconds: to, preferredTimescale: timescale)
        )

        await exporter.export()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(
                domain: "Kioku.Reconcile",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Audio slice export failed."]
            )
        }
        return tempURL
    }


    // Shared alignment driver — model prep, progress messaging, error handling. Both
    // `retimeFromAudio` (script = existing SRT) and `reconcileFromNote` (script = note text)
    // route through here so timing UI, cancellation, and the Apply/Cancel review sheet behave
    // identically. The aligner emits VAD-aware ♪ alongside speech lines, so no post-processing
    // is needed for music markers. `onProgress` updates the toolbar pill with a real-time
    // percentage so the user can tell the difference between "Whisper is still working" and
    // "Whisper got stuck" — vital because alignment on a 4-minute track easily runs a minute
    // and a spinner alone offers nothing to distinguish the two.
    @MainActor
    private func runAlignment(lines: [String], sourceLabel: String) async {
        defer {
            isRetiming = false
            retimeProgressMessage = ""
            retimeTask = nil
        }

        guard let audioURL = NotesAudioStore.shared.audioURL(for: attachmentID) else {
            retimeError = "No audio is attached to this note."
            return
        }

        guard lines.isEmpty == false else {
            retimeError = "No \(sourceLabel) to align."
            return
        }
        let lyrics = lines.joined(separator: "\n")

        isRetiming = true
        retimeProgressMessage = "Preparing model…"

        // Use an existing on-device model when available; otherwise download the default one.
        let modelURL: URL
        do {
            if let existing = OnDeviceLyricAligner.bestAvailableModelURL() {
                modelURL = existing
            } else {
                modelURL = try await OnDeviceLyricAligner.downloadDefaultModel { message in
                    Task { @MainActor in retimeProgressMessage = message }
                }
            }
        } catch {
            retimeError = "Couldn't prepare the alignment model: \(error.localizedDescription)"
            return
        }

        let alignStartedAt = Date()
        retimeProgressMessage = "Aligning \(lines.count) lines — 0%"

        do {
            let srt = try await OnDeviceLyricAligner.align(
                audioURL: audioURL,
                lyrics: lyrics,
                modelURL: modelURL,
                cancellationCheck: { Task.isCancelled },
                onProgress: { fraction in
                    // Aligner emits the 0–1 fraction from a background dispatch; route
                    // back to MainActor for the @State write. Format keeps the pill
                    // compact: percentage + elapsed seconds so the user reads it as
                    // "is this thing making progress" at a glance.
                    Task { @MainActor in
                        let pct = Int((fraction * 100).rounded())
                        let elapsed = Int(Date().timeIntervalSince(alignStartedAt))
                        retimeProgressMessage = "Aligning \(lines.count) lines — \(pct)% · \(elapsed)s"
                    }
                }
            )
            // Stage for the review sheet (Apply / Cancel) so the original SRT stays in
            // the editor until the user confirms.
            pendingRetimedSRT = srt
        } catch {
            if Task.isCancelled { return }
            retimeError = "Alignment failed: \(error.localizedDescription)"
        }
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

    // Binds the re-time error alert.
    private var retimeErrorPresented: Binding<Bool> {
        Binding(
            get: { retimeError.isEmpty == false },
            set: { if !$0 { retimeError = "" } }
        )
    }

    // Binds the re-time review sheet to whether a freshly aligned SRT is awaiting confirmation.
    private var retimeReviewPresented: Binding<Bool> {
        Binding(
            get: { pendingRetimedSRT != nil },
            set: { if !$0 { pendingRetimedSRT = nil } }
        )
    }

    // Binds the validation result alert.
    private var validationResultPresented: Binding<Bool> {
        Binding(
            get: { validationResult != nil },
            set: { if !$0 { validationResult = nil } }
        )
    }

    // Binds the validation error alert.
    private var validationErrorPresented: Binding<Bool> {
        Binding(
            get: { validationError.isEmpty == false },
            set: { if !$0 { validationError = "" } }
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
