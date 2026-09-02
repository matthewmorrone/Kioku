import Foundation

// Where a breakdown's listen-along render currently stands. Equatable so SongStepperView
// can key an `.onChange` off it (via SongListenStore's published dictionary) to know when
// to load a freshly-ready track into the playback controller.
enum SongListenRenderState: Equatable {
    case rendering(progress: Double)
    case ready(url: URL)
    case failed(String)
}
