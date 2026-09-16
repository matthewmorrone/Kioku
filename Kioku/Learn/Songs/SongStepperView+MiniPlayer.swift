import AVFoundation
import SwiftUI

// Persistent floating transport bar for the breakdown: play/pause, previous/next, and the
// current position (intro / "Line N of M" / outro). Pinned to the bottom of SongStepperView via
// `.safeAreaInset` so it never covers the last card, and its position survives leaving and
// reopening the breakdown — including an app relaunch — via SongListenStore (see
// currentPlaybackStep's wiring in SongStepperView's body).
//
// "Next"/"previous" walk the same line order the cards are shown in; stepping past either end
// plays the song's own intro (before the first line) or outro (after the last line) from the
// note's original audio file via `introOutroPlayback` — the narrated listen-along track
// (`listenPlayback`) can't do this itself, since it's a synthesized narration with TTS
// interleaved between lines and has no notion of the song's own timeline.
extension SongStepperView {

    var miniPlayerBar: some View {
        HStack(spacing: 14) {
            Button {
                previousMiniPlayerStep()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canStepPrevious ? Color.primary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(canStepPrevious == false)
            .accessibilityLabel("Previous")

            Button {
                toggleMiniPlayerPlayback()
            } label: {
                Circle()
                    .fill(Color(.systemOrange).opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: isMiniPlayerPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(.systemOrange))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isMiniPlayerPlaying ? "Pause" : "Play")

            Button {
                nextMiniPlayerStep()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canStepNext ? Color.primary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(canStepNext == false)
            .accessibilityLabel("Next")

            Spacer(minLength: 8)

            Text(miniPlayerPositionLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }

    // The label the bar shows for `currentPlaybackStep`.
    var miniPlayerPositionLabel: String {
        switch currentPlaybackStep {
        case .intro: return "Intro"
        case .line(let index): return "Line \(index) of \(displayItems.count)"
        case .outro: return "Outro"
        }
    }

    var isMiniPlayerPlaying: Bool {
        listenPlayback.isPlaying || introOutroPlayback.isPlaying
    }

    // Stepping between lines always works (narration doesn't need a matched sung clip); only
    // stepping past either end into the intro/outro needs there to actually BE one — a first
    // line already at ms 0 has no intro, and a last line already at the source's end has no
    // outro. Checking just "some line matched a cue" (as this used to) left the button enabled
    // in those cases even though playIntro()/playOutro() would then no-op.
    private var canStepPrevious: Bool {
        switch currentPlaybackStep {
        case .intro: return false
        case .outro: return true
        case .line(let index):
            if displayItems.contains(where: { $0.line.index < index }) { return true }
            guard let firstStartMs = lineRangesByIndex.values.map({ $0.startMs }).min() else { return false }
            return firstStartMs > 0
        }
    }

    private var canStepNext: Bool {
        switch currentPlaybackStep {
        case .outro: return false
        case .intro: return true
        case .line(let index):
            if displayItems.contains(where: { $0.line.index > index }) { return true }
            guard let sourceURL = listenSourceAudioURL,
                  let lastEndMs = lineRangesByIndex.values.map({ $0.endMs }).max(),
                  let durationMs = Self.sourceAudioDurationMs(sourceURL) else { return false }
            return lastEndMs < durationMs
        }
    }

    // Reads a local audio file's total duration via its header alone (no decode) — used only
    // to gate whether outro playback actually has anything after the last matched line, so the
    // "Next" button isn't left enabled-but-a-no-op when the last line already reaches the end
    // of the source file.
    private static func sourceAudioDurationMs(_ url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return Int(Double(file.length) / sampleRate * 1000)
    }

    // MARK: - Transport

    func toggleMiniPlayerPlayback() {
        if listenPlayback.isPlaying {
            pauseListen()
            return
        }
        if introOutroPlayback.isPlaying {
            introOutroPlayback.pause()
            return
        }
        switch currentPlaybackStep {
        case .intro:
            if loadedIntroOutroURL != nil, introOutroPlayback.currentTimeMs > 0 {
                introOutroPlayback.play()
            } else {
                playIntro()
            }
        case .outro:
            if loadedIntroOutroURL != nil, introOutroPlayback.currentTimeMs > 0 {
                introOutroPlayback.play()
            } else {
                playOutro()
            }
        case .line(let index):
            introOutroPlayback.pause()
            if let line = displayItems.first(where: { $0.line.index == index })?.line {
                playListen(line: line)
            } else {
                playAllListen()
            }
        }
    }

    // Advances the mini player one step forward: intro → first line → ... → last line → outro.
    func nextMiniPlayerStep() {
        switch currentPlaybackStep {
        case .intro:
            introOutroPlayback.pause()
            if let first = displayItems.first?.line {
                playListen(line: first)
            }
        case .line(let index):
            introOutroPlayback.pause()
            if let next = displayItems.first(where: { $0.line.index > index }) {
                playListen(line: next.line)
            } else {
                playOutro()
            }
        case .outro:
            break
        }
    }

    // Steps the mini player one step back: outro → last line → ... → first line → intro.
    func previousMiniPlayerStep() {
        switch currentPlaybackStep {
        case .intro:
            break
        case .line(let index):
            if let previous = displayItems.last(where: { $0.line.index < index }) {
                introOutroPlayback.pause()
                playListen(line: previous.line)
            } else {
                playIntro()
            }
        case .outro:
            if let last = displayItems.last?.line {
                introOutroPlayback.pause()
                playListen(line: last)
            } else {
                playIntro()
            }
        }
    }

    // MARK: - Intro / outro

    // Plays the song's own audio from its very start (or a previously-saved position within
    // that span — see SongListenStore.lastIntroOutroPositionMs) up to the first matched line's
    // cue — the instrumental (or vocal) intro before the lyrics being broken down begin.
    func playIntro() {
        guard let sourceURL = listenSourceAudioURL,
              let firstStartMs = lineRangesByIndex.values.map({ $0.startMs }).min(),
              firstStartMs > 0 else { return }
        listenPlayback.pause()
        let isFreshLoad = loadedIntroOutroURL != sourceURL
        loadIntroOutroSourceIfNeeded(sourceURL) {
            var startMs = 0
            if isFreshLoad {
                let saved = listenStore.lastIntroOutroPositionMs(forNoteID: note.id)
                if saved > 0, saved < firstStartMs { startMs = saved }
            }
            introOutroPlayback.playRange(startMs: startMs, endMs: firstStartMs)
        }
        currentPlaybackStep = .intro
    }

    // Plays the song's own audio from the last matched line's cue end (or a previously-saved
    // position within that span) through the end of the file — the outro after the lyrics
    // being broken down finish.
    func playOutro() {
        guard let sourceURL = listenSourceAudioURL,
              let lastEndMs = lineRangesByIndex.values.map({ $0.endMs }).max() else { return }
        listenPlayback.pause()
        let isFreshLoad = loadedIntroOutroURL != sourceURL
        loadIntroOutroSourceIfNeeded(sourceURL) {
            let durationMs = Int(introOutroPlayback.duration * 1000)
            guard durationMs > lastEndMs else { return }
            var startMs = lastEndMs
            if isFreshLoad {
                let saved = listenStore.lastIntroOutroPositionMs(forNoteID: note.id)
                if saved > lastEndMs, saved < durationMs { startMs = saved }
            }
            introOutroPlayback.playRange(startMs: startMs, endMs: durationMs)
        }
        currentPlaybackStep = .outro
    }

    // Loads the note's original audio into `introOutroPlayback` if it isn't already, then runs
    // `thenPlay` — deferred so `introOutroPlayback.duration` (needed by playOutro) is only read
    // once the file is actually loaded.
    private func loadIntroOutroSourceIfNeeded(_ sourceURL: URL, thenPlay: () -> Void) {
        if loadedIntroOutroURL != sourceURL {
            do {
                try introOutroPlayback.load(audioURL: sourceURL, cues: [], title: note.resolvedTitle)
                loadedIntroOutroURL = sourceURL
            } catch {
                print("[SongStepperView] intro/outro source load failed: \(error.localizedDescription)")
                return
            }
        }
        thenPlay()
    }
}
