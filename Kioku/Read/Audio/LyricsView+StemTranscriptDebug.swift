import SwiftUI
import UIKit

// Debug-only: dump the vocal-stem ASR transcript for the current song and show it in a copyable
// sheet. It answers the diagnostic question behind mis-timed lines — does the recognizer actually
// "hear" a line where it's sung (so the aligner could have anchored it there), or hear nothing
// (an ASR ceiling, not an alignment bug)? Triggered by a long-press on LyricsView's timing readout.
// Split into its own file so LyricsView stays under the per-file line cap.
extension LyricsView {
    // One transcript line per ASR phrase: "m:ss.mmm – m:ss.mmm  heard text". Plain text so it can
    // be selected/copied out of the sheet and pasted back for analysis.
    private var transcriptText: String {
        guard let stemTranscript, stemTranscript.isEmpty == false else { return "(no phrases recognized)" }
        return stemTranscript
            .map { "\(compactMs($0.startMs)) – \(compactMs($0.endMs))  \($0.text)" }
            .joined(separator: "\n")
    }

    // Copyable sheet showing the raw stem transcript.
    var transcriptSheet: some View {
        NavigationStack {
            ScrollView {
                Text(transcriptText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Stem transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showTranscriptSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy") { UIPasteboard.general.string = transcriptText }
                }
            }
        }
    }

    // Transcribes the current song's isolated vocal stem and opens the transcript sheet.
    func dumpStemTranscript() {
        guard isDumpingTranscript == false, let attachmentID,
              let mixURL = NotesAudioStore.shared.audioURL(for: attachmentID) else { return }
        isDumpingTranscript = true
        transcriptStatus = "Transcribing vocals…"
        Task {
            do {
                let cues = try await AudioTranscriptionService.transcribe(
                    url: mixURL, engine: .qwen3, isolateVocals: true
                )
                await MainActor.run {
                    stemTranscript = cues
                    isDumpingTranscript = false
                    showTranscriptSheet = true
                }
            } catch {
                await MainActor.run {
                    transcriptStatus = "Transcribe failed: \(error.localizedDescription)"
                    isDumpingTranscript = false
                }
            }
        }
    }
}
