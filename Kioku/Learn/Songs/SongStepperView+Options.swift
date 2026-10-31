import SwiftUI

// The Breakdown toolbar's options menu, split out of SongStepperView to keep that file under
// the size cap.
extension SongStepperView {
    // The toolbar's options menu: listen-along behaviour (pause at line ends, how many times each
    // word is heard before its definition), which kinds of word and line are shown (see
    // SongWordVisibility), plus Open Line in Lyrics (the mini player's line) and Regenerate.
    // Changing the repeat count or what's shown rebuilds the script, since it changes which steps
    // exist.
    var optionsMenu: some View {
        Menu {
            Toggle(isOn: $pauseAfterEachLine) {
                Label("Pause After Each Line", systemImage: "pause.circle")
            }
            Picker(selection: $wordWalk) {
                ForEach(BreakdownWordWalk.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                Label("Walk Through Words", systemImage: "list.bullet.indent")
            }
            .pickerStyle(.menu)
            Picker(selection: $wordRepeatCount) {
                ForEach(BreakdownListenSettings.wordRepeatChoices, id: \.self) { count in
                    Text("\(count)×").tag(count)
                }
            } label: {
                Label("Repeat Each Word", systemImage: "repeat")
            }
            .pickerStyle(.menu)
            Section("Show") {
                Toggle(isOn: $repeatEarlierWords) {
                    Label("Repeated Words", systemImage: "text.badge.checkmark")
                }
                Toggle(isOn: $showParticles) {
                    Label("Particles", systemImage: "link")
                }
                Toggle(isOn: $showKatakana) {
                    Label("Katakana Words", systemImage: "textformat")
                }
                Toggle(isOn: $showVocalizations) {
                    Label("Vocalizations", systemImage: "music.note")
                }
                Toggle(isOn: $showPatterns) {
                    Label("Patterns to Bank", systemImage: "lightbulb")
                }
            }
            Divider()
            if note.audioAttachmentID != nil, let line = currentStepLine {
                Button {
                    openLineInLyrics(line)
                } label: {
                    Label("Open Line in Lyrics", systemImage: "music.mic")
                }
            }
            Button {
                isRegenerateConfirmationPresented = true
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Options")
        .onChange(of: wordRepeatCount) { _, _ in configureLiveListen() }
        .onChange(of: repeatEarlierWords) { _, _ in configureLiveListen() }
        .onChange(of: wordVisibility) { _, _ in configureLiveListen() }
        .onChange(of: pauseAfterEachLine) { _, pause in liveListen.pauseAfterEachLine = pause }
    }
}
