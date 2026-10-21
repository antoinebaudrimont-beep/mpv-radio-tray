// Shared state machine used by the native controller and deterministic checks.
public struct PlaybackIntent {
    public private(set) var station: Station?
    public private(set) var paused = false
    public private(set) var sleeping = false
    public private(set) var terminated = false
    public private(set) var outputAvailable = true
    private var recovery: RecoveryPolicy
    public var shouldPlay: Bool { station != nil && !paused && !sleeping && !terminated && outputAvailable }

    public init(now: Double) { recovery = RecoveryPolicy(now: now) }
    public mutating func select(_ station: Station, now: Double) {
        guard !terminated else { return }
        self.station = station
        paused = false
        recovery = RecoveryPolicy(now: now)
    }
    public mutating func stop(now: Double) {
        station = nil
        paused = false
        recovery = RecoveryPolicy(now: now)
    }
    public mutating func pause() {
        guard !terminated, station != nil else { return }
        paused = true
    }
    public mutating func resume(now: Double) {
        guard !terminated, station != nil, paused else { return }
        paused = false
        recovery = RecoveryPolicy(now: now)
    }
    public mutating func sleep() { if !terminated { sleeping = true } }
    public mutating func wake(now: Double) {
        guard !terminated else { return }
        sleeping = false
        recovery = RecoveryPolicy(now: now)
    }
    public mutating func setOutputAvailable(_ available: Bool, now: Double) {
        outputAvailable = available
        if available { recovery = RecoveryPolicy(now: now) }
    }
    public mutating func shutdown(now: Double) {
        stop(now: now)
        sleeping = false
        terminated = true
    }
    public mutating func didStart(now: Double) { recovery.didStart(now: now) }
    public mutating func retry(now: Double, health: PlaybackHealth) -> RecoveryReason? {
        guard shouldPlay else { return nil }
        return recovery.retry(now: now, health: health)
    }
}
