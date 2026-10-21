import Foundation
import RadioCore

final class StationTests {
    func testPreservesOrderLabelsAndURLs() throws {
        let text = "# comment\r\n Galaxy 92.92 |http://galaxy.live24.gr:80/galaxy9292\r\n\nRED FM 96.3|https://stream.radiojar.com/redfm963\n"
        let stations = try Station.parse(text)
        expectEqual(stations.map(\.name), ["Galaxy 92.92", "RED FM 96.3"])
        expectEqual(stations.last?.url, "https://stream.radiojar.com/redfm963")
    }

    func testMalformedStationFailsWithLineNumber() {
        for invalid in ["missing separator", "|https://example.org/a", "Name|", "Name|--script=bad", "Name|file:///etc/passwd", "Name|https://"] {
            expectThrows(try Station.parse("# ok\n\(invalid)")) { error in
                expectTrue(error.localizedDescription.contains("line 2"))
            }
        }
    }

    func testEmptyFileIsValid() throws {
        let stations = try Station.parse("# comment\n")
        expectEqual(stations, [])
    }
}

final class RecoveryTests {
    func waitingDeadline() {
        var policy = RecoveryPolicy(now: 0)
        let waiting = PlaybackHealth(waiting: true)
        expectNil(policy.retry(now: 0, health: waiting))
        expectNil(policy.retry(now: 11, health: waiting))
        expectNil(policy.retry(now: 29, health: waiting))
        expectEqual(policy.retry(now: 30, health: waiting), .waiting)
    }
    func waitingResetsAfterRecovery() {
        var policy = RecoveryPolicy(now: 0)
        _ = policy.retry(now: 0, health: PlaybackHealth(waiting: true))
        _ = policy.retry(now: 20, health: PlaybackHealth(position: 1))
        expectNil(policy.retry(now: 25, health: PlaybackHealth(waiting: true)))
        expectNil(policy.retry(now: 54, health: PlaybackHealth(waiting: true)))
        expectEqual(policy.retry(now: 55, health: PlaybackHealth(waiting: true)), .waiting)
    }
    func failureAndCooldown() {
        var policy = RecoveryPolicy(now: 0)
        expectEqual(policy.retry(now: 1, health: PlaybackHealth(failure: .failed)), .failed)
        policy.didStart(now: 1)
        expectNil(policy.retry(now: 30, health: PlaybackHealth(failure: .ended)))
        expectEqual(policy.retry(now: 31, health: PlaybackHealth(failure: .ended)), .ended)
    }
    func stallRequiresProgress() {
        var policy = RecoveryPolicy(now: 0)
        expectNil(policy.retry(now: 0, health: PlaybackHealth(position: 1)))
        expectNil(policy.retry(now: 60, health: PlaybackHealth(position: 1)))
        expectNil(policy.retry(now: 65, health: PlaybackHealth(position: 2)))
        expectNil(policy.retry(now: 94, health: PlaybackHealth(position: 2)))
        expectEqual(policy.retry(now: 95, health: PlaybackHealth(position: 2)), .stalled)
    }
    func intentionalPause() {
        var policy = RecoveryPolicy(now: 0)
        _ = policy.retry(now: 0, health: PlaybackHealth(position: 1))
        _ = policy.retry(now: 5, health: PlaybackHealth(position: 2))
        expectNil(policy.retry(now: 100, health: PlaybackHealth(paused: true, position: 2)))
        expectNil(policy.retry(now: 105, health: PlaybackHealth(position: 2)))
    }
    func restartClearsOldProgress() {
        var policy = RecoveryPolicy(now: 0)
        _ = policy.retry(now: 0, health: PlaybackHealth(position: 1))
        _ = policy.retry(now: 5, health: PlaybackHealth(position: 2))
        policy.didStart(now: 100)
        expectNil(policy.retry(now: 150, health: PlaybackHealth(position: 1)))
    }
    func unsupportedDoesNotLoop() {
        var policy = RecoveryPolicy(now: 0)
        for time in [0.0, 30, 60, 120] {
            expectNil(policy.retry(now: time, health: PlaybackHealth(failure: .unsupported, waiting: true)))
        }
    }
    func unknownPositionIsSafe() {
        var policy = RecoveryPolicy(now: 0)
        for position in [Double.nan, .infinity, -.infinity] {
            expectNil(policy.retry(now: 100, health: PlaybackHealth(position: position)))
        }
    }
}

final class IntentTests {
    private let first = Station(name: "First", url: "https://example.org/one")
    private let second = Station(name: "Second", url: "https://example.org/two")
    func startsStopped() {
        let intent = PlaybackIntent(now: 0)
        expectNil(intent.station)
        expectFalse(intent.shouldPlay)
    }
    func switching() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        expectTrue(intent.shouldPlay)
        expectEqual(intent.station, first)
        intent.select(second, now: 1)
        expectEqual(intent.station, second)
    }
    func stopPreventsRestart() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.stop(now: 1)
        expectNil(intent.station)
        expectFalse(intent.shouldPlay)
        expectNil(intent.retry(now: 100, health: PlaybackHealth(failure: .failed)))
    }
    func manualSelectionResetsCooldown() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        expectEqual(intent.retry(now: 1, health: PlaybackHealth(failure: .failed)), .failed)
        intent.didStart(now: 1)
        expectNil(intent.retry(now: 2, health: PlaybackHealth(failure: .failed)))
        intent.select(second, now: 3)
        expectEqual(intent.retry(now: 4, health: PlaybackHealth(failure: .failed)), .failed)
    }
    func sleepWake() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.sleep()
        expectFalse(intent.shouldPlay)
        expectEqual(intent.station, first)
        expectNil(intent.retry(now: 60, health: PlaybackHealth(failure: .failed)))
        intent.wake(now: 65)
        expectTrue(intent.shouldPlay)
        expectEqual(intent.station, first)
    }
    func stopWhileSleeping() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.sleep()
        intent.stop(now: 10)
        intent.wake(now: 60)
        expectFalse(intent.shouldPlay)
        expectNil(intent.station)
    }
    func pausePreventsRecovery() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.pause()
        expectTrue(intent.paused)
        expectFalse(intent.shouldPlay)
        expectEqual(intent.station, first)
        for time in [30.0, 100, 1000] {
            expectNil(intent.retry(now: time, health: PlaybackHealth(failure: .failed)))
            expectNil(intent.retry(now: time, health: PlaybackHealth(failure: .ended)))
            expectNil(intent.retry(now: time, health: PlaybackHealth(waiting: true)))
        }
    }
    func pauseSurvivesSleepAndOutputReturn() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.pause()
        intent.sleep()
        intent.setOutputAvailable(false, now: 1)
        intent.wake(now: 60)
        intent.setOutputAvailable(true, now: 61)
        expectTrue(intent.paused)
        expectFalse(intent.shouldPlay)
        expectEqual(intent.station, first)
        expectNil(intent.retry(now: 100, health: PlaybackHealth(failure: .failed)))
        intent.resume(now: 101)
        expectFalse(intent.paused)
        expectTrue(intent.shouldPlay)
    }
    func resumeResetsRecovery() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        expectEqual(intent.retry(now: 1, health: PlaybackHealth(failure: .failed)), .failed)
        intent.didStart(now: 1)
        intent.pause()
        intent.resume(now: 2)
        expectEqual(intent.retry(now: 3, health: PlaybackHealth(failure: .failed)), .failed)

        intent.select(first, now: 10)
        expectNil(intent.retry(now: 10, health: PlaybackHealth(waiting: true)))
        intent.pause()
        intent.resume(now: 100)
        expectNil(intent.retry(now: 100, health: PlaybackHealth(waiting: true)))
        expectNil(intent.retry(now: 129, health: PlaybackHealth(waiting: true)))
        expectEqual(intent.retry(now: 130, health: PlaybackHealth(waiting: true)), .waiting)
    }
    func duplicateResumePreservesRecovery() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        expectNil(intent.retry(now: 0, health: PlaybackHealth(waiting: true)))
        intent.resume(now: 29)
        expectEqual(intent.retry(now: 30, health: PlaybackHealth(waiting: true)), .waiting)
    }
    func selectionAndStopClearPause() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.pause()
        intent.select(second, now: 1)
        expectFalse(intent.paused)
        expectTrue(intent.shouldPlay)
        expectEqual(intent.station, second)
        intent.pause()
        intent.stop(now: 2)
        intent.resume(now: 3)
        intent.pause()
        expectNil(intent.station)
        expectFalse(intent.paused)
        expectFalse(intent.shouldPlay)
    }
    func resumeRespectsSuspensionAndShutdown() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.pause()
        intent.sleep()
        intent.setOutputAvailable(false, now: 1)
        intent.resume(now: 2)
        expectFalse(intent.paused)
        expectFalse(intent.shouldPlay)
        intent.wake(now: 3)
        expectFalse(intent.shouldPlay)
        intent.setOutputAvailable(true, now: 4)
        expectTrue(intent.shouldPlay)
        intent.pause()
        intent.shutdown(now: 5)
        intent.resume(now: 6)
        intent.pause()
        expectTrue(intent.terminated)
        expectFalse(intent.paused)
        expectNil(intent.station)
        expectFalse(intent.shouldPlay)
    }
    func shutdownIsFinal() {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.shutdown(now: 1)
        intent.wake(now: 2)
        intent.select(second, now: 3)
        expectTrue(intent.terminated)
        expectNil(intent.station)
        expectFalse(intent.shouldPlay)
        expectNil(intent.retry(now: 100, health: PlaybackHealth(failure: .failed)))
    }
}

// A small throwing test runner keeps checks usable with Command Line Tools alone.
// XCTest is supplied by full Xcode, which is not required to build this application.
private var failures: [String] = []
private func expectTrue(_ value: @autoclosure () -> Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) {
    if !value() { failures.append("\(file):\(line): \(message)") }
}
private func expectFalse(_ value: @autoclosure () -> Bool, _ message: String = "Expected false", file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(!value(), message, file: file, line: line)
}
private func expectEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, file: StaticString = #filePath, line: UInt = #line) {
    let a = lhs(), b = rhs()
    expectTrue(a == b, "Expected \(a) to equal \(b)", file: file, line: line)
}
private func expectNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    expectTrue(value() == nil, "Expected nil", file: file, line: line)
}
private func expectThrows<T>(_ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line, inspect: (Error) -> Void = { _ in }) {
    do { _ = try value(); failures.append("\(file):\(line): Expected an error") }
    catch { inspect(error) }
}

@main
struct CoreChecks {
    static func main() {
        let stations = StationTests(), recovery = RecoveryTests(), intent = IntentTests()
        let checks: [(String, () throws -> Void)] = [
            ("Station labels, URLs and order", stations.testPreservesOrderLabelsAndURLs),
            ("Station validation and error line", stations.testMalformedStationFailsWithLineNumber),
            ("Empty station file", stations.testEmptyFileIsValid),
            ("Waiting threshold and startup grace", recovery.waitingDeadline),
            ("Waiting resets after healthy playback", recovery.waitingResetsAfterRecovery),
            ("Failure/end retry and cooldown across restart", recovery.failureAndCooldown),
            ("Stall requires earlier progress", recovery.stallRequiresProgress),
            ("Intentional pause avoids retry", recovery.intentionalPause),
            ("Restart clears previous progress", recovery.restartClearsOldProgress),
            ("Unsupported stream avoids retry loop", recovery.unsupportedDoesNotLoop),
            ("Nonfinite playback time", recovery.unknownPositionIsSafe),
            ("Startup stopped", intent.startsStopped),
            ("Station switching state", intent.switching),
            ("Stop prevents restart", intent.stopPreventsRestart),
            ("Manual selection resets cooldown", intent.manualSelectionResetsCooldown),
            ("Sleep/wake retains station", intent.sleepWake),
            ("Stop during sleep prevents wake playback", intent.stopWhileSleeping),
            ("Intentional pause blocks watchdog recovery", intent.pausePreventsRecovery),
            ("Pause survives sleep and output reconnect", intent.pauseSurvivesSleepAndOutputReturn),
            ("Resume resets cooldown and waiting deadline", intent.resumeResetsRecovery),
            ("Duplicate resume preserves recovery deadline", intent.duplicateResumePreservesRecovery),
            ("Selection and Stop clear pause", intent.selectionAndStopClearPause),
            ("Resume respects suspension and shutdown", intent.resumeRespectsSuspensionAndShutdown),
            ("Shutdown prevents further playback", intent.shutdownIsFinal)
        ]
        for (name, test) in checks {
            let before = failures.count
            do { try test() } catch { failures.append("\(name): \(error.localizedDescription)") }
            print("\(failures.count == before ? "PASS" : "FAIL"): \(name)")
        }
        let outputFailures = runOutputChecks()
        for failure in failures { fputs("\(failure)\n", stderr) }
        print("\(checks.count) checks, \(failures.count) failures")
        if !failures.isEmpty || outputFailures > 0 { exit(1) }
    }
}
