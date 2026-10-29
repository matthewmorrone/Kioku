import SwiftUI

// The sung-order preview, pushed from the alignment issue list: the note's lines rearranged into
// the order the aligner's any-order pass heard them sung (SungOrderDecoder), with each stretch of
// singing no note line explains filled with what on-device transcription hears there. It is all in
// one editable text field, since the guess is rough; Apply & Re-align writes it over the note's
// lyrics and aligns again.
//
// Layout: a progress row while the stretches are transcribed, then the times of stretches where
// no words were recognized, then the editable lyrics; toolbar Apply & Re-align.
struct SungOrderPreviewView: View {
    let entries: [LyricSungOrderEntry]
    let canTranscribe: Bool
    // The words heard in a stretch (start, end ms); nil when transcription failed.
    let onTranscribe: (Int, Int) async -> String?
    // Writes the edited lyrics over the note's and re-aligns; false when that couldn't be done.
    let onApply: (String) -> Bool

    @State private var lyrics = ""
    @State private var isPreparing = true
    @State private var unheard: [LyricSungOrderEntry] = []
    @State private var didFail = false

    var body: some View {
        Form {
            if isPreparing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Transcribing the parts the note has no lines for…")
                        .foregroundStyle(.secondary)
                }
            } else {
                if unheard.isEmpty == false {
                    Section {
                        ForEach(unheard, id: \.self) { entry in
                            Text("No words recognized at \(SubtitleTimecode.clock(ms: entry.startMs))–\(SubtitleTimecode.clock(ms: entry.endMs)). Lyrics the note doesn't have are sung there.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if didFail {
                    Text("Couldn't change the note's lyrics.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Section {
                    TextEditor(text: $lyrics)
                        .font(.body)
                        .frame(minHeight: 320)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Apply & Re-align") { didFail = onApply(lyrics) == false }
                    .disabled(isPreparing || lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task { await prepare() }
    }

    // Builds the editable lyrics once: note lines in sung order, each unexplained stretch replaced
    // by its transcription (or listed in `unheard` when nothing was recognized).
    private func prepare() async {
        guard isPreparing else { return }
        var out: [String] = []
        var missing: [LyricSungOrderEntry] = []
        for entry in entries {
            if let line = entry.lineText {
                out.append(line)
            } else if canTranscribe, let heard = await onTranscribe(entry.startMs, entry.endMs), heard.isEmpty == false {
                out.append(heard)
            } else {
                missing.append(entry)
            }
        }
        lyrics = out.joined(separator: "\n")
        unheard = missing
        isPreparing = false
    }
}
