import Foundation
import MediaPlayer
import RadioCore

enum RadioRemoteCommand: String {
    case play, pause, stop, toggle
}

// Publish this app's real playback to macOS so media commands can reach it.
// This does not change another app's state or force ownership of system controls.
final class NowPlayingController {
    private let info = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private let logger: RadioLogger
    private var targets: [(MPRemoteCommand, Any)] = []
    private var handler: ((RadioRemoteCommand) -> MPRemoteCommandHandlerStatus)?
    private var lastStation: Station?
    private var lastState: MPNowPlayingPlaybackState?
    private var lastRate: Double?
    private var stopped = false

    init(logger: RadioLogger, handler: @escaping (RadioRemoteCommand) -> MPRemoteCommandHandlerStatus) {
        self.logger = logger
        self.handler = handler
        for (command, action) in [(commands.playCommand, RadioRemoteCommand.play),
                                  (commands.pauseCommand, .pause),
                                  (commands.stopCommand, .stop),
                                  (commands.togglePlayPauseCommand, .toggle)] {
            command.isEnabled = false
            let target = command.addTarget { [weak self] _ in
                let perform = { () -> MPRemoteCommandHandlerStatus in
                    guard let self, !self.stopped, let handler = self.handler else { return .commandFailed }
                    let result = handler(action)
                    self.logger.write("Media command: \(action.rawValue); result=\(result.rawValue)")
                    return result
                }
                return Thread.isMainThread ? perform() : DispatchQueue.main.sync(execute: perform)
            }
            targets.append((command, target))
        }
        for command in [commands.nextTrackCommand, commands.previousTrackCommand,
                        commands.skipForwardCommand, commands.skipBackwardCommand,
                        commands.seekForwardCommand, commands.seekBackwardCommand,
                        commands.changePlaybackPositionCommand, commands.changePlaybackRateCommand,
                        commands.changeRepeatModeCommand, commands.changeShuffleModeCommand,
                        commands.ratingCommand, commands.likeCommand, commands.dislikeCommand,
                        commands.bookmarkCommand, commands.enableLanguageOptionCommand,
                        commands.disableLanguageOptionCommand] {
            command.isEnabled = false
        }
    }

    func update(station: Station?, state: MPNowPlayingPlaybackState, rate: Double) {
        guard !stopped else { return }
        // A watchdog tick must not continually reassert the app as Now Playing.
        guard station != lastStation || state != lastState || rate != lastRate else { return }
        lastStation = station
        lastState = state
        lastRate = rate
        for (command, _) in targets { command.isEnabled = station != nil }
        if let station {
            info.nowPlayingInfo = [
                MPMediaItemPropertyTitle: station.name,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: rate,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
            ]
        } else {
            info.nowPlayingInfo = nil
        }
        // On macOS AVPlayer alone does not provide this required media-control state.
        info.playbackState = state
        logger.write("Now Playing: state=\(state.rawValue); station=\(station != nil); rate=\(rate)")
    }

    func shutdown() {
        guard !stopped else { return }
        update(station: nil, state: .stopped, rate: 0)
        stopped = true
        handler = nil
        for (command, target) in targets {
            command.isEnabled = false
            command.removeTarget(target)
        }
        targets.removeAll()
    }

    deinit { shutdown() }
}
