public enum PlaybackFailure: Equatable {
    case failed, ended, unsupported
}

public enum RecoveryReason: String {
    case failed = "stream failed"
    case ended = "stream ended"
    case waiting = "prolonged buffering"
    case stalled = "playback stopped progressing"
}

public struct PlaybackHealth {
    public var failure: PlaybackFailure?
    public var waiting: Bool
    public var paused: Bool
    public var position: Double?
    public init(failure: PlaybackFailure? = nil, waiting: Bool = false,
                paused: Bool = false, position: Double? = nil) {
        self.failure = failure
        self.waiting = waiting
        self.paused = paused
        self.position = position
    }
}

public struct RecoveryPolicy {
    public static let grace: Double = 12
    public static let waitingLimit: Double = 30
    public static let progressLimit: Double = 30
    public static let cooldown: Double = 30
    private var started: Double
    private var lastRetry: Double?
    private var waitingSince: Double?
    private var lastPosition: Double?
    private var lastProgress: Double
    private var hasProgressed = false

    public init(now: Double) { started = now; lastProgress = now }

    public mutating func didStart(now: Double) {
        let previous = lastRetry
        self = RecoveryPolicy(now: now)
        lastRetry = previous
    }

    public mutating func retry(now: Double, health: PlaybackHealth) -> RecoveryReason? {
        guard health.failure != .unsupported else { return nil }
        var reason: RecoveryReason?
        if health.failure == .failed { reason = .failed }
        else if health.failure == .ended { reason = .ended }
        else if health.paused && !health.waiting {
            waitingSince = nil
            lastProgress = now
        } else {
            if health.waiting {
                if waitingSince == nil { waitingSince = now }
                if now - started >= Self.grace, now - waitingSince! >= Self.waitingLimit { reason = .waiting }
            } else { waitingSince = nil }
            if let position = health.position, position.isFinite {
                if let previous = lastPosition {
                    if abs(position - previous) > 0.25 {
                        lastPosition = position
                        lastProgress = now
                        hasProgressed = true
                    } else if hasProgressed, now - started >= Self.grace,
                              now - lastProgress >= Self.progressLimit { reason = reason ?? .stalled }
                } else { lastPosition = position; lastProgress = now }
            }
        }
        guard let reason else { return nil }
        if let lastRetry, now - lastRetry < Self.cooldown { return nil }
        lastRetry = now
        return reason
    }
}
