import SwiftUI

// Where SongListenSheet's render pass currently stands. Own top-level enum (rather than
// nested in the view) per the repo's no-nested-types rule.
enum SongListenRenderState {
    case rendering(progress: Double)
    case ready(url: URL)
    case failed(String)
}

// Sheet presented from the breakdown's "Listen" toolbar button. Renders the breakdown to
// audio on-device via SongListenAudioService, plays it back through a scratch
// AudioPlaybackController, and offers a ShareLink so the generated track can be exported
// (AirDrop, Files, Messages, ...) rather than staying trapped in-app.
struct SongListenSheet: View {
    let breakdown: SongBreakdown
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = AudioPlaybackController()
    @State private var state: SongListenRenderState = .rendering(progress: 0)

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                switch state {
                case .rendering(let progress):
                    renderingView(progress: progress)
                case .ready(let url):
                    readyView(url: url)
                case .failed(let message):
                    failedView(message)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .navigationTitle("Listen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await render() }
        .onDisappear { playback.unload() }
    }

    // In-flight render state: a progress bar plus a one-line reminder of what's about to
    // play, so a long song's synthesis doesn't read as a frozen screen.
    private func renderingView(progress: Double) -> some View {
        VStack(spacing: 14) {
            ProgressView(value: progress)
            Text("Generating listen-along audio…")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Japanese sentence, English gist, then each word — line by line.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
    }

    // Playback controls once the track exists: a big play/pause button, an elapsed/total
    // readout, and the export affordance — the only way to get the file out of this sheet.
    private func readyView(url: URL) -> some View {
        VStack(spacing: 20) {
            Button {
                playback.isPlaying ? playback.pause() : playback.play()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            if playback.duration > 0 {
                Text(timeLabel(playback.currentTimeMs) + " / " + timeLabel(Int(playback.duration * 1000)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ShareLink(item: url) {
                Label("Export Audio", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
    }

    // Render failure state (e.g. synthesis threw). Shows the error verbatim and offers a
    // one-tap retry rather than leaving the user stuck on a blank sheet.
    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                Task { await render() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Drives one render pass: synthesize the whole track, load it into the scratch player,
    // and start playback immediately so the user doesn't have to tap play right after
    // waiting for generation. Re-entrant — Retry calls this again from a clean `.rendering`
    // state.
    private func render() async {
        state = .rendering(progress: 0)
        do {
            let url = try await SongListenAudioService().renderAudio(for: breakdown) { fraction in
                state = .rendering(progress: fraction)
            }
            try playback.load(audioURL: url, cues: [])
            state = .ready(url: url)
            playback.play()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // Formats a millisecond offset as m:ss for the elapsed/total readout.
    private func timeLabel(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
