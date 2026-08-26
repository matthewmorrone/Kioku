import SwiftUI

// Where a breakdown's listen-along render currently stands. Own top-level enum (rather than
// nested in the view) per the repo's no-nested-types rule. Equatable so SongListenSheet can
// key an `.onChange` off it (via SongListenStore's published dictionary) to know when to load
// a freshly-ready track into the playback controller.
enum SongListenRenderState: Equatable {
    case rendering(progress: Double)
    case ready(url: URL)
    case failed(String)
}

// Sheet presented from the breakdown's "Listen" toolbar button. Displays the render/playback
// state owned by SongListenStore (so dismissing this sheet mid-render or mid-playback never
// loses progress — see that store's header comment), plays the track back through a scratch
// AudioPlaybackController, shows the full transcript with the currently-playing segment
// highlighted (the exact text and its timing are already known, since we generated the audio
// ourselves), and offers a ShareLink so the track can be exported (AirDrop, Files, Messages,
// ...) rather than staying trapped in-app.
struct SongListenSheet: View {
    let breakdown: SongBreakdown
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var listenStore: SongListenStore
    @StateObject private var playback = AudioPlaybackController()
    // The URL playback was last loaded for, so a body re-evaluation (e.g. a progress tick
    // from an unrelated note's render) doesn't reload/reseek/replay an already-loaded track.
    @State private var loadedURL: URL?

    private var state: SongListenRenderState {
        listenStore.renderState(forNoteID: breakdown.noteID)
    }

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
        .task {
            listenStore.ensureRendered(for: breakdown)
            loadIfReady()
        }
        .onChange(of: listenStore.renderStateByNoteID[breakdown.noteID]) { _, _ in
            loadIfReady()
        }
        .onDisappear {
            listenStore.recordPosition(playback.currentTimeMs, forNoteID: breakdown.noteID)
            playback.unload()
        }
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

    // Playback controls plus the highlighted transcript once the track exists: a scrolling,
    // auto-following list of every segment (sentence, gist, word, definition) with whichever
    // one is currently playing picked out, a play/pause button, an elapsed/total readout, and
    // the export affordance — the only way to get the file out of this sheet.
    private func readyView(url: URL) -> some View {
        VStack(spacing: 20) {
            transcriptView

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

    // Scrolling transcript of every synthesized segment, highlighting whichever one is
    // currently playing and auto-scrolling to keep it in view. Reuses
    // AudioPlaybackController.activeCueIndex — the same mechanism the karaoke Read view
    // drives its highlighting from — against the cues SongListenAudioService stamped with
    // real timing during synthesis.
    private var transcriptView: some View {
        let cues = listenStore.cues(forNoteID: breakdown.noteID)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(cues.enumerated()), id: \.offset) { index, cue in
                        Text(cue.text)
                            .font(.body)
                            .foregroundStyle(index == playback.activeCueIndex ? Color.primary : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                if index == playback.activeCueIndex {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.16))
                                }
                            }
                            .id(index)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 320)
            .onChange(of: playback.activeCueIndex) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
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
                listenStore.retry(for: breakdown)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // Loads a newly (or already) ready track into the scratch player and resumes from
    // wherever playback last left off, then starts playing — so the user doesn't have to tap
    // play right after waiting for generation, and doesn't land back at 0:00 after leaving and
    // returning mid-song. No-op if this URL is already loaded (guards against redundant
    // reloads from unrelated body re-evaluations).
    private func loadIfReady() {
        guard case .ready(let url) = state, loadedURL != url else { return }
        loadedURL = url
        do {
            try playback.load(audioURL: url, cues: listenStore.cues(forNoteID: breakdown.noteID))
            let resumeMs = listenStore.lastPositionMs(forNoteID: breakdown.noteID)
            if resumeMs > 0 {
                playback.seek(toMs: resumeMs)
            }
            playback.play()
        } catch {
            // Loaded-but-unplayable is rare (e.g. the cached file was removed mid-session);
            // the transcript still renders from the cached cues, playback controls just won't
            // do anything until the user retries generation.
        }
    }

    // Formats a millisecond offset as m:ss for the elapsed/total readout.
    private func timeLabel(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
