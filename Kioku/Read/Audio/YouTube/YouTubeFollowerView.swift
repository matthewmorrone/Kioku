import SwiftUI

// The muted YouTube video shown full-screen behind the lyrics. Layout: one video surface cropped to
// fill its container (or letterboxed whole, per the fit setting), following the song's playback, or a one-line notice when it can't be embedded.
// The song's own audio file stays the clock; this view only forwards its play state and position.
struct YouTubeFollowerView: View {
    @ObservedObject var audio: AudioPlaybackController
    @StateObject private var player: YouTubePlayerController
    // True to show the whole video letterboxed; false to crop it to fill the screen.
    @AppStorage(YouTubeFollowerView.fitsScreenKey) private var fitsScreen = false

    private let videoID: String
    // True for the blurred copy that fills the screen behind a fitted video; it always crops to fill.
    private let isAmbient: Bool

    static let fitsScreenKey = "youtubeVideoFitsScreen"

    // Creates the player for `videoID`, following `audio`. The controller is built inside the
    // autoclosure so SwiftUI creates it once; building it outside would spawn a new web view (and a
    // page reload) on every refresh of the parent.
    init(videoID: String, audio: AudioPlaybackController, isAmbient: Bool = false) {
        self.videoID = videoID
        self.isAmbient = isAmbient
        self.audio = audio
        _player = StateObject(wrappedValue: YouTubePlayerController(videoID: videoID))
    }

    // Full-bleed video behind the lyrics (cropped to fill, like a lyric-video backdrop), or a small
    // notice when YouTube refuses to play it inline.
    var body: some View {
        ZStack {
            // Fitted video leaves bars; a blurred, enlarged copy of the same video behind it fills them.
            if fitsScreen && isAmbient == false && player.errorCode == nil {
                YouTubeFollowerView(videoID: videoID, audio: audio, isAmbient: true)
                    .scaleEffect(1.2)
                    // A material over the copy does the blurring: a blur filter applied to the web
                    // view itself renders black.
                    .overlay(Rectangle().fill(.thinMaterial).environment(\.colorScheme, .dark))
            }
            videoLayer
        }
        .clipped()
    }

    // The video surface itself, cropped to fill or fitted whole, with the sync hooks.
    private var videoLayer: some View {
        GeometryReader { geo in
            if let code = player.errorCode {
                Text(code == 101 || code == 150 ? "This video's owner doesn't allow embedding." : "The video couldn't be played (error \(code)).")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .padding(.top, 60)
            } else {
                // The page letterboxes a 16:9 video inside its frame, so the frame is widened to
                // the video's shape and centred; the overflow is clipped, which crops it to fill.
                // Fit mode skips the widening so the whole picture shows inside the screen.
                let fits = fitsScreen && isAmbient == false
                // Fit mode sizes the surface to exactly the video's shape, so the page's own black
                // letterbox bars don't exist and the blurred copy behind shows above and below.
                let width = fits ? min(geo.size.width, geo.size.height * 16.0 / 9.0) : max(geo.size.width, geo.size.height * 16.0 / 9.0)
                YouTubePlayerView(controller: player)
                    .frame(width: width, height: fits ? width * 9.0 / 16.0 : max(geo.size.height, width * 9.0 / 16.0))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .onChange(of: audio.isPlaying) { _, _ in syncVideo() }
        // A jump between lines moves the audio's position far more than one playback tick does. The
        // page's own position report only arrives twice a second, so a jump (or any scrub while
        // paused) is forwarded here at once and the video seeks with the audio.
        .onChange(of: audio.currentTimeMs) { old, new in
            if audio.isPlaying == false || abs(new - old) > 700 { syncVideo() }
        }
        .onChange(of: player.isReady) { _, _ in syncVideo() }
        .onAppear {
            player.audioState = { [weak audio] in
                guard let audio else { return (false, 0, 0) }
                return (audio.isPlaying, Double(audio.currentTimeMs) / 1000, audio.duration)
            }
            syncVideo()
        }
        .onDisappear { player.teardown() }
    }

    // Asks the video follower to re-check itself against the audio.
    private func syncVideo() {
        player.sync()
    }
}
