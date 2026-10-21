import AVFoundation
import Foundation
import MediaPlayer
import RadioCore

struct PlayerViewState {
    var station: Station?
    var message = "Stopped"
    var isPaused = false
    var canSelectAirPlay = false
}

// AppKit and AVFoundation state are confined to the main thread. The same player
// survives station changes and recovery, retaining its requested audio output.
final class PlayerController {
    let player = AVPlayer()
    private let logger: RadioLogger
    private lazy var nowPlaying = NowPlayingController(logger: logger) { [weak self] command in
        self?.handleRemoteCommand(command) ?? .commandFailed
    }
    private var intent = PlaybackIntent(now: ProcessInfo.processInfo.systemUptime)
    private var timer: Timer?
    private var playerObservation: NSKeyValueObservation?
    private var itemObservations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var failure: PlaybackFailure?
    private var signalledStall = false
    private var lastState = ""
    private var requestedOutputUID: String?
    var onChange: ((PlayerViewState) -> Void)?
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    init(logger: RadioLogger) {
        self.logger = logger
        player.automaticallyWaitsToMinimizeStalling = true
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateNowPlaying()
    }

    func play(_ station: Station) {
        guard !intent.terminated else { return }
        intent.select(station, now: now)
        if intent.shouldPlay { startSelected(reason: "station selected") }
        else { publishSuspended() }
    }

    func selectOutput(uid: String?, available: Bool) {
        guard !intent.terminated else { return }
        let wasAvailable = intent.outputAvailable
        guard requestedOutputUID != uid || wasAvailable != available else { return }
        requestedOutputUID = uid
        intent.setOutputAvailable(available, now: now)
        if !available {
            detachItem()
            publishSuspended()
            return
        }
        player.audioOutputDeviceUniqueID = uid
        if !wasAvailable {
            if intent.shouldPlay { startSelected(reason: "output available") }
            else { publishSuspended() }
        }
    }

    func stop() {
        guard !intent.terminated else { return }
        intent.stop(now: now)
        detachItem()
        publish("Stopped")
        logger.write("Playback stopped")
    }

    func pause() {
        guard !intent.terminated, intent.station != nil else { return }
        intent.pause()
        // Live radio resumes at the live edge rather than keeping a paused connection.
        detachItem()
        publishSuspended()
    }

    func resume() {
        guard !intent.terminated, intent.station != nil else { return }
        intent.resume(now: now)
        guard intent.shouldPlay else { publishSuspended(); return }
        if player.currentItem == nil { startSelected(reason: "resume") }
        else {
            // AirPlay may send Play while radio is already playing. Do not replace it.
            player.play()
            updateNowPlaying()
        }
    }

    func handleRemoteCommand(_ command: RadioRemoteCommand) -> MPRemoteCommandHandlerStatus {
        guard !intent.terminated else { return .commandFailed }
        guard intent.station != nil else { return .noActionableNowPlayingItem }
        switch command {
        case .stop: stop()
        case .pause: pause()
        case .play, .toggle:
            if command == .toggle && !intent.paused { pause() }
            else {
                guard !intent.sleeping else { return .commandFailed }
                guard intent.outputAvailable else { return .deviceNotFound }
                resume()
            }
        }
        return .success
    }

    private func publishSuspended() {
        guard let station = intent.station else { publish("Stopped"); return }
        if intent.paused { publish("Paused: \(station.name)") }
        else if intent.sleeping { publish("Sleeping") }
        else { publish("Output unavailable — reconnect or choose another output") }
    }

    private func startSelected(reason: String) {
        guard intent.shouldPlay, let station = intent.station, let url = URL(string: station.url) else { return }
        detachItem()
        intent.didStart(now: now)
        player.audioOutputDeviceUniqueID = requestedOutputUID
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 10
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        player.replaceCurrentItem(with: item)
        observe(item, \.status)
        observe(item, \.isPlaybackBufferEmpty)
        observe(item, \.isPlaybackLikelyToKeepUp)
        for name in [AVPlayerItem.failedToPlayToEndTimeNotification,
                     AVPlayerItem.playbackStalledNotification, AVPlayerItem.didPlayToEndTimeNotification,
                     AVPlayerItem.newErrorLogEntryNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self, weak item] note in
                guard let self, let item, self.player.currentItem === item, self.intent.shouldPlay else { return }
                if note.name == AVPlayerItem.failedToPlayToEndTimeNotification {
                    self.failure = .failed
                    self.logError(item.error ?? note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
                } else if note.name == AVPlayerItem.didPlayToEndTimeNotification { self.failure = .ended }
                else if note.name == AVPlayerItem.playbackStalledNotification {
                    self.signalledStall = true
                    self.logger.write("Playback stalled")
                } else if let event = item.errorLog()?.events.last {
                    self.logger.write("Stream error log status=\(event.errorStatusCode)")
                }
                self.evaluate()
            })
        }
        logger.write("Station start: \(station.name); reason=\(reason)")
        publish("Connecting: \(station.name)…")
        player.play()
    }

    private func observe<Value>(_ item: AVPlayerItem, _ path: KeyPath<AVPlayerItem, Value>) {
        itemObservations.append(item.observe(path, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.player.currentItem === item else { return }
                self.evaluate()
            }
        })
    }

    private func evaluate() {
        guard intent.shouldPlay, let item = player.currentItem else { return }
        if item.status == .failed {
            if failure == nil { logError(item.error) }
            let error = item.error as NSError?
            if error?.domain == AVFoundationErrorDomain,
               error?.code == AVError.Code.fileFormatNotRecognized.rawValue || error?.code == AVError.Code.decoderNotFound.rawValue {
                failure = .unsupported
            } else { failure = .failed }
        }
        if player.timeControlStatus == .playing && !item.isPlaybackBufferEmpty { signalledStall = false }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate || signalledStall || item.isPlaybackBufferEmpty
        let position = player.currentTime().seconds
        let health = PlaybackHealth(failure: failure, waiting: waiting,
            paused: player.timeControlStatus == .paused && item.status == .readyToPlay,
            position: position.isFinite ? position : nil)
        if let reason = intent.retry(now: now, health: health) {
            logError(item.error)
            logger.write("Recovery: \(reason.rawValue)")
            startSelected(reason: reason.rawValue)
            return
        }
        if failure == .unsupported {
            publish("Unsupported stream — choose another station")
        } else if failure != nil {
            publish("Stream failed — waiting to retry")
        } else if player.timeControlStatus == .playing {
            signalledStall = false
            publish("Playing: \(intent.station!.name)")
        } else if waiting {
            publish("Buffering: \(intent.station!.name)…")
        } else { publish("Paused: \(intent.station!.name)") }
    }

    private func publish(_ message: String) {
        updateNowPlaying()
        if message != lastState {
            logger.write(message)
            lastState = message
        }
        onChange?(PlayerViewState(station: intent.station, message: message,
            isPaused: intent.paused,
            canSelectAirPlay: intent.shouldPlay && player.timeControlStatus == .playing))
    }

    private func updateNowPlaying() {
        let state: MPNowPlayingPlaybackState
        if intent.station == nil || intent.terminated { state = .stopped }
        else if intent.paused { state = .paused }
        else if intent.sleeping || !intent.outputAvailable || failure != nil { state = .interrupted }
        else { state = .playing }
        let rate = intent.shouldPlay && player.timeControlStatus == .playing ? Double(player.rate) : 0
        nowPlaying.update(station: intent.station, state: state, rate: rate)
    }

    private func logError(_ error: Error?) {
        guard let error = error as NSError? else { return }
        logger.write("Playback failure domain=\(error.domain); code=\(error.code)")
    }

    private func detachItem() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        failure = nil
        signalledStall = false
    }

    func sleep() {
        guard !intent.terminated else { return }
        intent.sleep()
        detachItem()
        logger.write("Sleep: playback suspended")
        publishSuspended()
    }

    func wake() {
        guard !intent.terminated else { return }
        intent.wake(now: now)
        logger.write("Wake: reconnecting if a station was selected")
        if intent.shouldPlay { startSelected(reason: "wake") }
        else { publishSuspended() }
    }

    func shutdown() {
        guard !intent.terminated else { return }
        intent.shutdown(now: now)
        timer?.invalidate()
        timer = nil
        playerObservation?.invalidate()
        playerObservation = nil
        detachItem()
        nowPlaying.shutdown()
        onChange = nil
        logger.write("Playback stopped for shutdown")
    }
}
