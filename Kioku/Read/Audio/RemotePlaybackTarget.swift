import Foundation

// A player the lock screen / Control Center transport buttons can drive. RemoteCommandRouter sends
// each command to whichever conforming player last claimed ExclusivePlayback. Each call returns
// false when the player has nothing loaded to act on.
@MainActor
protocol RemotePlaybackTarget: AnyObject {
    var isPlaying: Bool { get }
    // The lock screen's play: resume what the card shows.
    func remotePlay() -> Bool
    // The lock screen's pause: stop in place so play resumes there.
    func remotePause() -> Bool
    // Scrubbing on the card's progress bar, for players with a timeline.
    func remoteSeek(toSeconds seconds: Double) -> Bool
    // Back or forward a lyric line (offset -1 / +1): the card's ⏮ ⏭.
    func remoteSkipLine(by offset: Int) -> Bool
}
