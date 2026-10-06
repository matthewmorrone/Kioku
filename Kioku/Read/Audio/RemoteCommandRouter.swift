import Foundation
import MediaPlayer

// Wires the lock-screen / Control Center transport buttons and the lyrics Live Activity's buttons
// to the app's players. MPRemoteCommandCenter
// is process-wide, while the app has several players (the Read song, the breakdown's intro/outro, the
// listen-along narration); registering once here and forwarding to the player that last started
// (ExclusivePlayback.current) means the buttons drive what the card is showing, and never wake a
// different player that happens to have a song loaded.
enum RemoteCommandRouter {
    private static var didRegister = false

    // Adds the command targets on first call; later calls are no-ops. Each player calls this from
    // its init so the buttons work whichever player is created first.
    static func registerIfNeeded() {
        guard didRegister == false else { return }
        didRegister = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            status(currentTarget.map { $0.remotePlay() })
        }
        center.pauseCommand.addTarget { _ in
            status(currentTarget.map { $0.remotePause() })
        }
        center.togglePlayPauseCommand.addTarget { _ in
            status(currentTarget.map { $0.isPlaying ? $0.remotePause() : $0.remotePlay() })
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return status(currentTarget.map { $0.remoteSeek(toSeconds: event.positionTime) })
        }
        // The card's track buttons step by lyric line: a note is one track, so there's no other
        // track to go to, and a line is the unit the lyrics move in.
        center.previousTrackCommand.addTarget { _ in
            status(currentTarget.map { $0.remoteSkipLine(by: -1) })
        }
        center.nextTrackCommand.addTarget { _ in
            status(currentTarget.map { $0.remoteSkipLine(by: 1) })
        }
        LyricsActivityCommandRelay.handler = { command in
            handle(command)
        }
    }

    // Carries out a Live Activity button press on the current player.
    private static func handle(_ command: LyricsActivityCommand) {
        guard let target = currentTarget else { return }
        let handled: Bool
        switch command {
        case .togglePlayback: handled = target.isPlaying ? target.remotePause() : target.remotePlay()
        case .previousLine: handled = target.remoteSkipLine(by: -1)
        case .nextLine: handled = target.remoteSkipLine(by: 1)
        }
        AppLog.info(.audioPlayback, "[RemoteCommandRouter] live activity \(command) handled=\(handled)")
    }

    // The player the buttons act on: the last one to claim ExclusivePlayback, if it takes remote
    // commands and is still alive.
    private static var currentTarget: RemotePlaybackTarget? {
        ExclusivePlayback.current as? RemotePlaybackTarget
    }

    // Maps a forwarded command's outcome to the status iOS expects: no player → no content, a
    // player with nothing loaded → failed.
    private static func status(_ handled: Bool?) -> MPRemoteCommandHandlerStatus {
        guard let handled else { return .noSuchContent }
        return handled ? .success : .commandFailed
    }
}
