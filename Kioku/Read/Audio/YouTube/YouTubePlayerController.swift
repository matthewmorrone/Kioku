import Combine
import Foundation
import WebKit

// Owns the web view that hosts YouTube's IFrame player and keeps it a silent follower of the app's
// own audio: the attached audio file stays the clock (and keeps lock-screen and background playback),
// while this video plays muted beside the lyrics and is nudged back whenever it drifts.
// The web view reports its position every half second; each report is the tick that decides whether
// to play, pause or seek the video.
@MainActor
final class YouTubePlayerController: NSObject, ObservableObject, WKScriptMessageHandler {
    // How far (seconds) the video may sit from the audio before it is seeked back.
    private static let driftTolerance = 0.45
    // The looser limit for a video of a different length, whose position only roughly tracks the song.
    private static let mismatchTolerance = 3.0
    // The IFrame API's state code while a video is playing.
    private static let playingState = 1
    // The IFrame API's state code when the video has played to its end.
    private static let endedState = 0

    let webView: WKWebView
    // False until the IFrame player is ready; nothing is sent to the page before then.
    @Published private(set) var isReady = false
    // The speed last sent to the player, so it is only resent when it changes.
    private var playbackRate = 1.0
    // The IFrame API's error code (101/150 = embedding disabled for this video), or nil.
    @Published private(set) var errorCode: Int?
    // The black borders baked into the video's picture, once found; the follower zooms past them.
    @Published private(set) var bars = YouTubeVideoBars.none

    private let videoID: String
    private var videoSeconds: Double = 0
    private var videoDuration: Double = 0
    private var videoState = -1
    // Reads the audio's live state (playing, seconds, duration). Read fresh on every tick, so a
    // position report never compares the video against a stale snapshot of the audio.
    var audioState: () -> (playing: Bool, seconds: Double, duration: Double) = { (false, 0, 0) }

    // Builds the web view and loads the player page for `videoID`.
    init(videoID: String) {
        self.videoID = videoID
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "yt")
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        // The page fills the whole web view. Left automatic, the web view reserves the status bar and
        // tab bar areas it overlaps when the video fills the screen, and black shows through there.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Nothing touches the page, so YouTube's hover and tap overlays (title, share, more videos) never appear.
        webView.isUserInteractionEnabled = false
        webView.loadHTMLString(Self.pageHTML(videoID: videoID), baseURL: URL(string: Self.embedOrigin))
        Task { [weak self] in
            let found = await YouTubeBarFinder.shared.bars(for: videoID)
            self?.bars = found
        }
    }

    // Detaches the script handler, which the web view's content controller otherwise retains.
    func teardown() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "yt")
        webView.stopLoading()
    }

    // Brings the video in line with the audio: plays or pauses to match, and seeks when it has
    // drifted (or when the audio was scrubbed while paused). Called on every position report and
    // whenever the audio's play state or position changes.
    func sync() {
        guard isReady else { return }
        let (audioPlaying, audioSeconds, audioDuration) = audioState()

        // A video whose length differs from the song's is a different cut, so its timestamps don't
        // line up with the audio's. Instead the whole video is spread across the whole song: the
        // video's position follows the song's in proportion, at the nearest playback speed the
        // player offers, with a seek whenever it strays. It only has to look right, so the
        // tolerance is loose.
        let isSameLength = videoDuration <= 0 || audioDuration <= 0 || abs(videoDuration - audioDuration) <= 3
        let ratio = isSameLength ? 1 : videoDuration / audioDuration
        let rate = isSameLength ? 1 : Self.nearestPlaybackRate(to: ratio)
        if rate != playbackRate {
            playbackRate = rate
            run("player.setPlaybackRate(\(rate))")
        }
        let target = audioSeconds * ratio
        if abs(videoSeconds - target) > (isSameLength ? Self.driftTolerance : Self.mismatchTolerance) {
            run("player.seekTo(\(target), true)")
            videoSeconds = target
        }
        let videoPlaying = videoState == Self.playingState
        if audioPlaying, videoPlaying == false {
            run("player.playVideo()")
        } else if audioPlaying == false, videoPlaying {
            run("player.pauseVideo()")
        }
    }

    // The playback speed the IFrame player offers (quarter steps from 0.25 to 2) closest to `ratio`.
    private static func nearestPlaybackRate(to ratio: Double) -> Double {
        min(2, max(0.25, (ratio * 4).rounded() / 4))
    }

    // Receives the page's reports: ready, state changes, errors and the periodic position.
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["t"] as? String else { return }
        let value = (body["v"] as? NSNumber)?.doubleValue ?? 0
        let duration = (body["d"] as? NSNumber)?.doubleValue ?? 0
        Task { @MainActor in
            switch kind {
            case "ready":
                isReady = true
                sync()
            case "state":
                videoState = Int(value)
                if Int(value) == Self.endedState, audioState().playing {
                    run("player.seekTo(0, true); player.playVideo()")
                }
                AppLog.info(.audioPlayback, "[YouTubePlayer] state \(Int(value))")
            case "error":
                errorCode = Int(value)
                AppLog.error(.audioPlayback, "[YouTubePlayer] player error \(Int(value))")
            case "time":
                videoSeconds = value
                videoDuration = duration
                sync()
            default:
                break
            }
        }
    }

    // Runs one line of the IFrame API in the page; failures are logged because a silent one would
    // leave the video visibly out of step with no trace.
    private func run(_ script: String) {
        AppLog.info(.audioPlayback, "[YouTubePlayer] run \(script) (video \(videoSeconds)/\(videoDuration)s state \(videoState))")
        webView.evaluateJavaScript(script + ";null") { _, error in
            if let error {
                AppLog.error(.audioPlayback, "[YouTubePlayer] \(script) failed — \(error.localizedDescription)")
            }
        }
    }

    // The origin the page presents to YouTube: the app's own identifier as an https host. Claiming
    // www.youtube.com itself is rejected (error 152), and an empty referrer is rejected too (153).
    private static var embedOrigin: String {
        "https://" + (Bundle.main.bundleIdentifier ?? "kioku.app").lowercased()
    }

    // The page that hosts the IFrame player: chrome-less, muted once ready, and reporting back.
    private static func pageHTML(videoID: String) -> String {
        """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{width:100%;height:100%;pointer-events:none}body::after{content:'';position:fixed;inset:0}</style>
        </head><body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function post(o){window.webkit.messageHandlers.yt.postMessage(o)}
        // Videos with caption tracks load their captions module when playback starts, whatever cc_load_policy says, so it is switched off again at every state change and on a timer.
        function noCaptions(){try{player.setOption('captions','track',{});player.unloadModule('captions');player.unloadModule('cc')}catch(e){}}
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(videoID)',
            playerVars:{playsinline:1,controls:0,iv_load_policy:3,cc_load_policy:0,rel:0,modestbranding:1,disablekb:1,fs:0,origin:'\(embedOrigin)'},
            events:{
              onReady:function(){player.mute();noCaptions();post({t:'ready'})},
              onStateChange:function(e){noCaptions();post({t:'state',v:e.data})},
              onError:function(e){post({t:'error',v:e.data})}}})}
        setInterval(function(){if(player&&player.getCurrentTime){noCaptions();post({t:'time',v:player.getCurrentTime(),d:player.getDuration()})}},500);
        </script></body></html>
        """
    }
}
