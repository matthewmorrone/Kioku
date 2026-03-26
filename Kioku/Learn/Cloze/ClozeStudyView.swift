import SwiftUI

// Renders an active cloze study session: sentence prompt with inline dropdown blanks, score header,
// and reveal/next controls. A settings sheet allows adjusting mode and blank count mid-session.
// Major sections: toolbar, score header, sentence prompt, reveal/next controls.
struct ClozeStudyView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ClozeStudyViewModel

    @State private var showingSettings = false

    @ScaledMetric(relativeTo: .title3) private var blankMinWidth: CGFloat = 96
    @ScaledMetric(relativeTo: .title3) private var blankHeight: CGFloat = 32
    @ScaledMetric(relativeTo: .title3) private var blankHPadding: CGFloat = 10

    // Stores the note and initial config so StateObject can be initialised in init.
    init(
        note: Note,
        initialMode: ClozeMode = .random,
        initialBlanksPerSentence: Int = 1,
        excludeDuplicateLines: Bool = true
    ) {
        _model = StateObject(wrappedValue: ClozeStudyViewModel(
            note: note,
            initialMode: initialMode,
            initialBlanksPerSentence: initialBlanksPerSentence,
            excludeDuplicateLines: excludeDuplicateLines
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                scoreHeader
                Divider()
                prompt
                controls
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    let title = model.note.title.isEmpty ? "Study" : model.note.title
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        Text(title).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Study settings")
                }
            }
            .onAppear { model.start() }
        }
        .sheet(isPresented: $showingSettings) {
            settingsSheet
        }
    }

    // Running score and mode/blank-count summary.
    private var scoreHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Score").foregroundStyle(.secondary)
                Spacer()
                Text("\(model.correctCount)/\(model.totalCount)").foregroundStyle(.secondary)
            }
            .font(.subheadline)

            if let q = model.currentQuestion {
                Text("Mode: \(model.mode.displayName) • \(q.blanks.count) blank(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if model.sentenceCount > 0 {
                Text("\(model.sentenceCount) sentence(s) in note")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // The sentence with inline dropdown controls replacing the blank tokens.
    private var prompt: some View {
        Group {
            if model.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Building question…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if let q = model.currentQuestion {
                VStack(alignment: .leading, spacing: 12) {
                    if #available(iOS 16.0, *) {
                        InlineWrapLayout(spacing: 0, lineSpacing: 8) {
                            ForEach(q.segments) { seg in
                                switch seg.kind {
                                case .text(let s):
                                    Text(s).font(.title3)
                                case .blank(let b):
                                    inlineDropdown(blank: b)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // Fallback for iOS 15: plain sentence text without inline dropdowns.
                        Text(q.sentenceText).font(.title3)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(.separator), lineWidth: 1))
            } else {
                VStack(spacing: 10) {
                    Text("No questions available").font(.headline)
                    Text("This note might be too short, or contains no eligible tokens.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    // An individual dropdown menu for one blank slot.
    private func inlineDropdown(blank b: ClozeBlank) -> some View {
        let selection = model.selectedOptionByBlankID[b.id] ?? "▾"
        let checked = model.checkedBlankIDs.contains(b.id)
        let isCorrect = checked && selection == b.correct
        let feedbackColor: Color = isCorrect ? .green : .red
        let borderColor: Color = checked ? feedbackColor : Color(.separator)

        return Menu {
            ForEach(b.options, id: \.self) { option in
                Button(option) { model.submitSelection(blankID: b.id, option: option) }
            }
        } label: {
            Text(selection)
                .font(.title3)
                .lineLimit(1)
                .foregroundStyle(checked ? feedbackColor : Color.accentColor)
                .padding(.horizontal, blankHPadding)
                .frame(minWidth: blankMinWidth, minHeight: blankHeight, alignment: .center)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer choices")
    }

    // Reveal and Next buttons below the sentence.
    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.revealAnswer() } label: {
                Label("Reveal", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .disabled(model.currentQuestion == nil || model.isLoading)

            Spacer()

            Button { Task { await model.nextQuestion() } } label: {
                Label("Next", systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isLoading)
        }
    }

    // In-session settings sheet for changing mode and blank count without leaving the session.
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Mode") {
                    Picker("Order", selection: $model.mode) {
                        ForEach(ClozeMode.allCases) { m in Text(m.displayName).tag(m) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Question") {
                    let maxBlanks = max(1, (model.currentQuestion?.wordCount ?? 2) - 1)
                    Stepper(
                        "Dropdowns per sentence: \(min(model.blanksPerSentence, maxBlanks))",
                        value: Binding(
                            get: { min(model.blanksPerSentence, maxBlanks) },
                            set: { model.blanksPerSentence = $0 }
                        ),
                        in: 1...maxBlanks
                    )
                    .onChange(of: model.blanksPerSentence) { _, _ in
                        model.rebuildCurrentQuestion()
                    }
                }

                Section {
                    Text("Settings apply immediately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingSettings = false }
                }
            }
        }
    }
}
