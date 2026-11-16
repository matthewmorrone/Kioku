import Foundation

// What a finished YouTube audio download hands back: the temporary .m4a and the video's title.
struct YouTubeAudioDownload {
    let fileURL: URL
    let title: String
}
