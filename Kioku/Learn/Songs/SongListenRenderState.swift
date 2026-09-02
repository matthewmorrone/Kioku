import Foundation

// Where a breakdown's listen-along render currently stands. Equatable so SongStepperView
// can key an `.onChange` off it (via SongListenStore's published dictionary) to know when
// to load a freshly-ready track into the playback controller.
enum SongListenRenderState: Equatable {
    case rendering(progress: Double)
    case ready(url: URL)
    case failed(String)
}

// What the breakdown toolbar's listen button shows: headphones (tap to play everything in
// sequence), a spinner while the track renders, pause while anything is playing, or a
// warning that retries a failed render. Derived per body pass by SongStepperView+Listen.
enum SongListenControlState: Equatable {
    case idle
    case rendering
    case playing
    case failed
}
