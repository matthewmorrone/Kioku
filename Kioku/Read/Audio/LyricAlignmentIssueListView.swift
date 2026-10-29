import SwiftUI
import LyricAlignment

// The list of places a finished alignment found the note's lyrics and the singing disagree:
// singing with no line placed on it, and lines spread over far more time than they can fill.
// Shown when an alignment finishes with any, and from the lyrics card's banner while any are left;
// the counterpart of the Breakdown's fix list. Listen plays the spot; Transcribe drafts the words
// sung there into an editable field, and Insert adds them to the note as a line of their own next
// to where they're sung (timed by the next Re-align) and drops the issue; Ignore drops one; Edit
// Lyrics opens the note.
//
// When the aligner also heard the lines in another order, a first section links to the editable
// sung-order preview (SungOrderPreviewView).
//
// Layout: a List with the sung-order section when there is one, then one section per issue (kind,
// time range, the line for a stretched one, what it usually means, the transcribed draft once
// there is one, buttons); toolbar Done and Edit Lyrics.
struct LyricAlignmentIssueListView: View {
    let issues: [LyricAlignmentIssue]
    // The order the lines seem to be sung in, when it isn't the note's; nil hides its section.
    let sungOrder: [LyricSungOrderEntry]?
    // Whether Transcribe is offered (on-device transcription needs iOS 26).
    let canTranscribe: Bool
    let onListen: (LyricAlignmentIssue) -> Void
    // The words heard in a stretch (start, end ms); nil when transcription failed.
    let onTranscribe: (Int, Int) async -> String?
    // Writes edited lyrics over the note's and re-aligns (the sung-order preview's Apply).
    let onApplySungOrder: (String) -> Bool
    // Inserts the draft into the note; false when its place in the note can't be found.
    let onInsert: (String, LyricAlignmentIssue) -> Bool
    let onIgnore: (LyricAlignmentIssue) -> Void
    let onEditLyrics: () -> Void
    let onDone: () -> Void

    // Per issue: the editable transcription draft, which are transcribing now, and which failed (to
    // transcribe, or to insert). An inserted issue leaves `issues`, so it needs no mark here.
    @State private var drafts: [Int: String] = [:]
    @State private var transcribingIDs: Set<Int> = []
    @State private var failures: [Int: String] = [:]

    var body: some View {
        List {
            if let sungOrder {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lines out of order")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("The song seems to sing these lyrics in a different order than the note has them, or repeats parts the note has once.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        NavigationLink("Review Sung Order") {
                            SungOrderPreviewView(
                                entries: sungOrder,
                                canTranscribe: canTranscribe,
                                onTranscribe: onTranscribe,
                                onApply: onApplySungOrder
                            )
                        }
                        .font(.body.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                }
            }
            if issues.isEmpty {
                Text("Nothing left to check.")
                    .foregroundStyle(.secondary)
            }
            ForEach(issues) { issue in
                Section {
                    row(issue)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done", action: onDone)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit Lyrics", action: onEditLyrics)
            }
        }
    }

    // One issue: its kind, when, the line it's about, what it usually means, and its buttons.
    private func row(_ issue: LyricAlignmentIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(kindLabel(issue.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(SubtitleTimecode.clock(ms: issue.startMs))–\(SubtitleTimecode.clock(ms: issue.endMs))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let lineText = issue.lineText {
                Text(lineText)
                    .font(.title3)
            }
            Text(explanation(issue))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let draft = drafts[issue.id] {
                TextField("Lyrics heard here", text: Binding(
                    get: { draft },
                    set: { drafts[issue.id] = $0 }
                ), axis: .vertical)
                .font(.title3)
                .textFieldStyle(.roundedBorder)
                Text("Speech recognition on singing is rough: correct this before inserting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = failures[issue.id] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Listen") { onListen(issue) }
                    .buttonStyle(.bordered)
                if canTranscribe {
                    if let draft = drafts[issue.id] {
                        Button("Insert") { insert(draft, for: issue) }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else if transcribingIDs.contains(issue.id) {
                        ProgressView()
                    } else {
                        Button("Transcribe") { transcribe(issue) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Button("Ignore") { onIgnore(issue) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // Transcribes the issue's stretch into its editable draft, or records why it couldn't.
    private func transcribe(_ issue: LyricAlignmentIssue) {
        failures[issue.id] = nil
        transcribingIDs.insert(issue.id)
        Task {
            let heard = await onTranscribe(issue.startMs, issue.endMs)
            transcribingIDs.remove(issue.id)
            switch heard {
            case nil: failures[issue.id] = "Couldn't transcribe this part."
            case let text? where text.isEmpty: failures[issue.id] = "No words were recognized here. Type them in, or use Edit Lyrics."; drafts[issue.id] = ""
            case let text?: drafts[issue.id] = text
            }
        }
    }

    // Inserts the edited draft into the note, or records that its place couldn't be found.
    private func insert(_ draft: String, for issue: LyricAlignmentIssue) {
        if onInsert(draft, issue) {
            failures[issue.id] = nil
            drafts[issue.id] = nil
        } else {
            failures[issue.id] = "Couldn't find where this goes in the note. Use Edit Lyrics instead."
        }
    }

    // The section label for an issue's kind.
    private func kindLabel(_ kind: AlignmentMismatchKind) -> String {
        switch kind {
        case .unmatchedSinging: return "Singing with no lyrics"
        case .stretchedLine: return "Line stretched out"
        }
    }

    // What the issue usually means, in a sentence.
    private func explanation(_ issue: LyricAlignmentIssue) -> String {
        let seconds = max(1, (issue.endMs - issue.startMs + 500) / 1000)
        switch issue.kind {
        case .unmatchedSinging:
            return "Someone is singing here for about \(seconds) s, but no line was placed on it. The note is probably missing these lyrics, or has them somewhere else."
        case .stretchedLine:
            return "This line was spread over \(seconds) s, much longer than it takes to sing, so it's probably covering other lyrics the note doesn't have here."
        }
    }
}
