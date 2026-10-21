import AppKit
import AVFoundation
import AVKit
import CoreAudio
import MediaPlayer
import RadioCore

private final class FakeDiscovery: AudioOutputDiscovery {
    var records: [AudioDeviceRecord] = []
    private var callback: (() -> Void)?
    func enumerate() throws -> [AudioDeviceRecord] { records }
    func start(onChange: @escaping () -> Void) { callback = onChange }
    func shutdown() { callback = nil }
    func change(_ records: [AudioDeviceRecord]) { self.records = records; callback?() }
}

// Exercises current controllers. Hardware routing checks use a stopped/muted
// player and built-in outputs only. No AirPlay receiver is selected automatically.
@main
struct NativeChecks {
    static func main() { exit(run()) }

    private static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func musicProcesses() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.Music" }.map(\.processIdentifier))
    }

    private static func routePicker(in view: NSView?) -> AVRoutePickerView? {
        guard let view else { return nil }
        if let picker = view as? AVRoutePickerView { return picker }
        return view.subviews.lazy.compactMap { routePicker(in: $0) }.first
    }

    private static func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        return predicate()
    }

    private static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let logger = RadioLogger()
        let controller = PlayerController(logger: logger)
        let discovery = CoreAudioOutputs(logger: logger)
        let defaultBefore = defaultOutput()
        let musicBefore = musicProcesses()
        defer { discovery.shutdown(); controller.shutdown(); logger.close() }
        precondition(controller.player.currentItem == nil && controller.player.rate == 0, "Must start stopped")
        let nowPlaying = MPNowPlayingInfoCenter.default()
        let remote = MPRemoteCommandCenter.shared()
        precondition(nowPlaying.nowPlayingInfo == nil && nowPlaying.playbackState == .stopped,
            "Stopped startup must not publish a phantom station")
        precondition(!remote.playCommand.isEnabled && !remote.togglePlayPauseCommand.isEnabled)
        precondition(controller.handleRemoteCommand(.play) == .noActionableNowPlayingItem,
            "A remote Play must not invent a station")

        let records: [AudioDeviceRecord]
        do { records = try discovery.enumerate() }
        catch { fputs("FAIL: public CoreAudio enumeration failed\n", stderr); return 1 }
        let devices = AudioOutputDevice.available(from: records)
        for record in records {
            print("DEVICE: \(record.name ?? "Unnamed"); UID=\(record.uid?.isEmpty == false ? "present" : "missing"); outputChannels=\(record.outputChannels); transport=\(record.transportType.map { String(format: "0x%08X", $0) } ?? "unknown"); alive=\(record.isAlive)")
        }
        precondition(devices.allSatisfy { output in records.contains { $0.uid == output.uid && $0.outputChannels > 0 && $0.isAlive } })
        print("PASS: live output capability and UID/name mapping")

        let suite = "radio-output-check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Test preferences unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeDiscovery()
        let first = AudioDeviceRecord(name: "First output", uid: "first", outputChannels: 2, transportType: nil)
        let second = AudioDeviceRecord(name: "Second output", uid: "second", outputChannels: 2, transportType: nil)
        fake.records = [first]
        let outputs = OutputController(logger: logger, defaults: defaults, discovery: fake)
        defer { outputs.shutdown() }
        var updates = 0
        outputs.onChange = { updates += 1 }
        outputs.start()
        outputs.select(first.uid)
        let restored = OutputController(logger: logger, defaults: defaults, discovery: FakeDiscovery())
        defer { restored.shutdown() }
        precondition(restored.selection.requestedUID == first.uid, "UID preference must persist")
        let beforeChange = updates
        fake.change([first, second])
        precondition(updates > beforeChange && outputs.selection.devices.count == 2, "Device callback must refresh")
        fake.change([second])
        precondition(!outputs.selection.isAvailable && outputs.selection.requestedUID == first.uid, "Disconnect must retain preference")
        fake.change([first, second])
        precondition(outputs.selection.isAvailable, "Reconnect must resolve saved output")
        outputs.select(nil)
        precondition(defaults.string(forKey: "audioOutputDeviceUID") == nil && outputs.selection.requestedUID == nil, "Default must clear UID preference")
        fake.change([AudioDeviceRecord(name: "Software device", uid: "virtual", outputChannels: 2,
            transportType: kAudioDeviceTransportTypeVirtual), first])
        defaults.set("virtual", forKey: "audioOutputDeviceUID")
        defaults.set("Software device", forKey: "audioOutputDeviceName")
        let legacy = OutputController(logger: logger, defaults: defaults, discovery: fake)
        legacy.start()
        precondition(legacy.selection.requestedUID == nil && legacy.selection.devices.allSatisfy { $0.uid != "virtual" }, "Excluded saved virtual output must reset without an unavailable menu entry")
        legacy.shutdown()
        print("PASS: preference persistence, device-list callback refresh, disconnect/reconnect, default reset, saved virtual-output cleanup")

        let builtIn = devices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
        if let builtIn {
            controller.selectOutput(uid: builtIn.uid, available: true)
            precondition(controller.player.audioOutputDeviceUniqueID == builtIn.uid, "Concrete output must map to AVPlayer UID")
            controller.stop()
            controller.sleep()
            controller.wake()
            precondition(controller.player.audioOutputDeviceUniqueID == builtIn.uid, "Stop/wake must retain UID")
            print("PASS: AVPlayer concrete UID assignment and stopped lifecycle retention")
        } else { print("SKIP: concrete UID assignment (no built-in output available)") }
        controller.selectOutput(uid: nil, available: true)
        precondition(controller.player.audioOutputDeviceUniqueID == nil, "Default must map to nil")
        print("PASS: AVPlayer System Default maps to nil")

        if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--popover" {
            let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            status.button?.title = "Radio check"
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let airPlay = AirPlayController(player: controller.player, logger: logger)
            defer { airPlay.shutdown(); NSStatusBar.system.removeStatusItem(status) }
            var preparations = 0
            airPlay.onWillPresentRoutes = {
                preparations += 1
                controller.selectOutput(uid: nil, available: true)
            }
            guard let button = status.button else { fatalError("Status button unavailable") }
            for _ in 0..<2 {
                if let builtIn { controller.selectOutput(uid: builtIn.uid, available: true) }
                let before = controller.player.audioOutputDeviceUniqueID
                airPlay.show(relativeTo: button)
                precondition(waitUntil {
                    airPlay.isPresented && app.windows.filter(\.isVisible).contains { routePicker(in: $0.contentView) != nil }
                }, "Native AirPlay popover must become visible")
                guard let picker = app.windows.filter(\.isVisible).compactMap({ routePicker(in: $0.contentView) }).first else {
                    fatalError("Native AirPlay popover did not appear")
                }
                precondition(picker.superview?.bounds.size == NSSize(width: 72, height: 64), "Popover must remain compact")
                precondition(picker.player === controller.player, "Picker must share the real radio player")
                precondition(controller.player.audioOutputDeviceUniqueID == before, "Opening host alone must not change output")
                airPlay.routePickerViewWillBeginPresentingRoutes(picker)
                precondition(controller.player.audioOutputDeviceUniqueID == nil, "Native routing must prepare System Default")
                airPlay.routePickerViewDidEndPresentingRoutes(picker)
                precondition(waitUntil {
                    !airPlay.isPresented && app.windows.filter(\.isVisible).allSatisfy { routePicker(in: $0.contentView) == nil }
                }, "Popover must close after native dismissal")
            }
            precondition(preparations == 2, "Each native opening must prepare routing")
            print("PASS: compact shared-player popover opens/closes twice; native routing prepares System Default")
        }

        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--stream" {
            let stations: [Station]
            do { stations = try Station.parse("Stream check|" + CommandLine.arguments[2]) }
            catch { fatalError("Invalid stream URL") }
            if let builtIn { controller.selectOutput(uid: builtIn.uid, available: true) }
            controller.player.isMuted = true
            controller.player.allowsExternalPlayback = false
            controller.play(stations[0])
            let deadline = Date().addingTimeInterval(45)
            var advanced = false
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                if controller.player.timeControlStatus == .playing && controller.player.currentTime().seconds > 0.5 { advanced = true; break }
            }
            guard advanced else { fputs("FAIL: stream did not advance within 45 seconds\n", stderr); return 1 }
            precondition(nowPlaying.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == stations[0].name)
            precondition(nowPlaying.nowPlayingInfo?[MPNowPlayingInfoPropertyIsLiveStream] as? Bool == true)
            precondition(nowPlaying.playbackState == .playing && remote.playCommand.isEnabled)
            precondition(!remote.changePlaybackPositionCommand.isEnabled && !remote.nextTrackCommand.isEnabled)
            let playingItem = controller.player.currentItem
            precondition(controller.handleRemoteCommand(.play) == .success)
            precondition(controller.player.currentItem === playingItem,
                "AirPlay Play command during playback must not restart the station")
            precondition(controller.handleRemoteCommand(.pause) == .success)
            precondition(controller.player.currentItem == nil && nowPlaying.playbackState == .paused)
            controller.sleep()
            precondition(controller.handleRemoteCommand(.play) == .commandFailed,
                "Media command must not resume while sleeping")
            controller.wake()
            let pausedUID = controller.player.audioOutputDeviceUniqueID
            controller.selectOutput(uid: "unavailable-test-device", available: false)
            precondition(controller.handleRemoteCommand(.play) == .deviceNotFound)
            controller.selectOutput(uid: pausedUID, available: true)
            RunLoop.main.run(until: Date().addingTimeInterval(5.2))
            precondition(controller.player.currentItem == nil && nowPlaying.playbackState == .paused,
                "Watchdog, wake and output return must preserve deliberate pause")
            precondition(controller.handleRemoteCommand(.toggle) == .success)
            precondition(controller.player.currentItem != nil && nowPlaying.playbackState == .playing)
            precondition(controller.handleRemoteCommand(.toggle) == .success)
            precondition(nowPlaying.playbackState == .paused)
            precondition(controller.handleRemoteCommand(.play) == .success)
            print("PASS: live Now Playing metadata, idempotent Play, pause/toggle/resume, watchdog and suspended lifecycle")
            let uid = controller.player.audioOutputDeviceUniqueID
            let previous = controller.player.currentItem!
            NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: previous)
            precondition(controller.player.currentItem !== previous && controller.player.audioOutputDeviceUniqueID == uid, "Recovery must retain concrete output")
            controller.play(Station(name: "Switched station", url: stations[0].url))
            precondition(controller.player.audioOutputDeviceUniqueID == uid, "Station switch must retain concrete output")
            precondition(nowPlaying.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Switched station")
            controller.selectOutput(uid: "unavailable-test-device", available: false)
            precondition(controller.player.currentItem == nil, "Missing output must suspend media")
            precondition(controller.handleRemoteCommand(.stop) == .success)
            controller.selectOutput(uid: uid, available: true)
            precondition(controller.player.currentItem == nil, "Stop during disconnect must prevent resume")
            precondition(nowPlaying.nowPlayingInfo == nil && nowPlaying.playbackState == .stopped)
            precondition(!remote.playCommand.isEnabled && !remote.stopCommand.isEnabled)
            precondition(controller.handleRemoteCommand(.play) == .noActionableNowPlayingItem)
            print("PASS: real muted stream, recovery/item replacement and station switching retain UID; missing-output Stop prevents resume")
        }
        controller.stop()
        controller.shutdown()
        precondition(controller.handleRemoteCommand(.play) == .commandFailed)
        precondition(nowPlaying.nowPlayingInfo == nil && !remote.togglePlayPauseCommand.isEnabled,
            "Shutdown must release metadata and remote controls")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(controller.player.currentItem == nil && controller.player.rate == 0, "Shutdown must detach media")
        guard defaultBefore == defaultOutput() else { fputs("FAIL: system default changed during check\n", stderr); return 1 }
        guard musicProcesses().subtracting(musicBefore).isEmpty else { fputs("FAIL: Music appeared during direct built-in UID check\n", stderr); return 1 }
        print("PASS: shutdown; system default unchanged; no new Music process during built-in UID checks")
        print("AirPlay routing and system media-command delivery require manual acceptance checks.")
        return 0
    }
}
