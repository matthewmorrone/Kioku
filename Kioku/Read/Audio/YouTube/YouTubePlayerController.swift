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
    // The IFrame API's state code while a video is playing.
    private static let playingState = 1
    // The IFrame API's state code when the video has played to its end.
    private static let endedState = 0

    let webView: WKWebView
    // False until the IFrame player is ready; nothing is sent to the page before then.
    @Published private(set) var isReady = false
    // True when the video's length differs from the audio's, so its timestamps can't be trusted.
    @Published private(set) var lengthMismatch = false
    // The IFrame API's error code (101/150 = embedding disabled for this video), or nil.
    @Published private(set) var errorCode: Int?

    private var videoSeconds: Double = 0
    private var videoDuration: Double = 0
    private var videoState = -1
    // Reads the audio's live state (playing, seconds, duration). Read fresh on every tick, so a
    // position report never compares the video against a stale snapshot of the audio.
    var audioState: () -> (playing: Bool, seconds: Double, duration: Double) = { (false, 0, 0) }

    // Builds the web view and loads the player page for `videoID`.
    init(videoID: String) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "yt")
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.loadHTMLString(Self.pageHTML(videoID: videoID), baseURL: URL(string: Self.embedOrigin))
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

        // A video whose length differs from the song's is a different cut (or an ad), so its
        // timestamps don't line up with the audio's. It then just plays and pauses with the song,
        // looping at its end, instead of being seeked to positions that mean something else.
        let isSameLength = videoDuration <= 0 || audioDuration <= 0 || abs(videoDuration - audioDuration) <= 3
        if lengthMismatch == isSameLength { lengthMismatch = !isSameLength }
        if isSameLength, abs(videoSeconds - audioSeconds) > Self.driftTolerance {
            run("player.seekTo(\(audioSeconds), true)")
            videoSeconds = audioSeconds
        }
        let videoPlaying = videoState == Self.playingState
        if audioPlaying, videoPlaying == false {
            run("player.playVideo()")
        } else if audioPlaying == false, videoPlaying {
            run("player.pauseVideo()")
        }
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
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function post(o){window.webkit.messageHandlers.yt.postMessage(o)}
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(videoID)',
            playerVars:{playsinline:1,controls:0,cc_load_policy:0,rel:0,modestbranding:1,disablekb:1,fs:0,origin:'\(embedOrigin)'},
            events:{
              onReady:function(){player.mute();try{player.unloadModule('captions');player.unloadModule('cc')}catch(e){};post({t:'ready'})},
              onStateChange:function(e){post({t:'state',v:e.data})},
              onError:function(e){post({t:'error',v:e.data})}}})}
        setInterval(function(){if(player&&player.getCurrentTime){post({t:'time',v:player.getCurrentTime(),d:player.getDuration()})}},500);
        </script></body></html>
        """
    }
}
