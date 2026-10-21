import RadioCore

func runOutputChecks() -> Int {
    var failures = 0
    var checks = 0
    func check(_ name: String, _ body: () -> Bool) {
        checks += 1
        let passed = body()
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL"): \(name)")
    }

    let speaker = AudioDeviceRecord(name: "Speakers", uid: "builtin-speakers",
                                    outputChannels: 2, transportType: 0x626C746E)
    let wireless = AudioDeviceRecord(name: "Headphones", uid: "bluetooth-headphones",
                                     outputChannels: 2, transportType: 0x626C7565)
    let first = Station(name: "First", url: "https://example.org/one")
    let second = Station(name: "Second", url: "https://example.org/two")
    let failed = PlaybackHealth(failure: .failed)

    check("Outputs exclude input-only, dead and missing-UID records") {
        let records = [
            AudioDeviceRecord(name: "Microphone", uid: "input", outputChannels: 0, transportType: nil),
            AudioDeviceRecord(name: "Disconnected", uid: "dead", outputChannels: 2,
                              transportType: nil, isAlive: false),
            AudioDeviceRecord(name: "Missing UID", uid: nil, outputChannels: 2, transportType: nil),
            AudioDeviceRecord(name: "Empty UID", uid: "", outputChannels: 2, transportType: nil),
            speaker
        ]
        return AudioOutputDevice.available(from: records).map(\.uid) == ["builtin-speakers"]
    }
    check("Virtual transport excludes arbitrary software outputs without name or UID matching") {
        let software = AudioDeviceRecord(name: "Arbitrary device", uid: "random-device-id",
                                          outputChannels: 2, transportType: 0x76697274)
        return AudioOutputDevice.available(from: [software, speaker]).map(\.uid) == [speaker.uid]
            && AudioOutputDevice.exclusionReason(for: software) == "virtual software device"
    }
    check("Physical output transports and aggregate devices remain eligible") {
        let transports: [UInt32?] = [
            0x626C746E, // Built-in
            0x75736220, // USB
            0x626C7565, // Bluetooth
            0x626C6561, // Bluetooth LE
            0x68646D69, // HDMI
            0x64707274, // DisplayPort
            0x7468756E, // Thunderbolt
            0x31333934, // FireWire
            0x70636920, // PCI
            0x67727570, // Aggregate
            0x12345678, // Other exposed transport
            nil
        ]
        let records = transports.enumerated().map { index, transport in
            AudioDeviceRecord(name: "Output \(index)", uid: "device-\(index)",
                              outputChannels: 2, transportType: transport)
        }
        return AudioOutputDevice.available(from: records).count == records.count
            && records.allSatisfy { AudioOutputDevice.exclusionReason(for: $0) == nil }
    }
    check("Device names do not exclude a valid physical output") {
        let physical = AudioDeviceRecord(name: "Microsoft Teams Audio", uid: "physical-usb",
                                          outputChannels: 2, transportType: 0x75736220)
        return AudioOutputDevice.available(from: [physical]).first?.uid == physical.uid
            && AudioOutputDevice.exclusionReason(for: physical) == nil
    }
    check("AirPlay transport is separate from direct CoreAudio output selection") {
        let airplay = AudioDeviceRecord(name: "Receiver", uid: "receiver-id",
                                         outputChannels: 2, transportType: 0x61697270)
        var selection = OutputSelection(requestedUID: airplay.uid)
        selection.update([speaker, airplay])
        return selection.devices.map(\.uid) == [speaker.uid] && !selection.isAvailable
            && selection.requestedUID == airplay.uid
            && AudioOutputDevice.exclusionReason(for: airplay) == "AirPlay uses the native route picker"
    }
    check("Output names, UIDs and transport types preserve real device identity") {
        let outputs = AudioOutputDevice.available(from: [speaker, wireless])
        return outputs.count == 2
            && outputs[0].name == "Headphones" && outputs[0].uid == "bluetooth-headphones"
            && outputs[0].transportType == wireless.transportType
            && outputs[1].name == "Speakers" && outputs[1].uid == "builtin-speakers"
            && outputs[1].transportType == speaker.transportType
    }
    check("Unnamed outputs retain their UID and a usable label") {
        let records = [AudioDeviceRecord(name: " \n", uid: "unnamed", outputChannels: 2, transportType: nil)]
        let outputs = AudioOutputDevice.available(from: records)
        return outputs.count == 1 && outputs[0].name == "Audio output"
            && outputs[0].uid == "unnamed" && outputs[0].transportType == nil
    }
    check("Duplicate output UIDs produce one device") {
        let duplicate = AudioDeviceRecord(name: "Duplicate", uid: speaker.uid,
                                          outputChannels: 2, transportType: 123)
        let outputs = AudioOutputDevice.available(from: [speaker, duplicate, wireless])
        return outputs.count == 2
            && outputs.first(where: { $0.uid == speaker.uid })?.name == speaker.name
            && outputs.first(where: { $0.uid == speaker.uid })?.transportType == speaker.transportType
    }
    check("Output ordering is stable with name ties and enumeration changes") {
        let records = [
            AudioDeviceRecord(name: "Zulu", uid: "z", outputChannels: 2, transportType: nil),
            AudioDeviceRecord(name: "Alpha", uid: "b", outputChannels: 2, transportType: nil),
            AudioDeviceRecord(name: "alpha", uid: "a", outputChannels: 2, transportType: nil)
        ]
        let outputs = AudioOutputDevice.available(from: records)
        return outputs.map(\.uid) == ["a", "b", "z"]
            && outputs == AudioOutputDevice.available(from: Array(records.reversed()))
    }
    check("System Default uses no concrete output UID") {
        var selection = OutputSelection()
        selection.update([speaker, wireless])
        guard selection.requestedUID == nil && selection.selectedDevice == nil && selection.isAvailable else {
            return false
        }
        selection.select(wireless.uid)
        selection.select(nil)
        return selection.requestedUID == nil && selection.selectedDevice == nil && selection.isAvailable
            && OutputSelection(requestedUID: "").requestedUID == nil
    }
    check("Concrete output selection resolves the requested device") {
        var selection = OutputSelection()
        selection.update([speaker, wireless])
        selection.select(wireless.uid)
        return selection.requestedUID == "bluetooth-headphones" && selection.isAvailable
            && selection.selectedDevice?.name == "Headphones"
            && selection.selectedDevice?.transportType == wireless.transportType
    }
    check("Missing output preserves its UID and resolves when it returns") {
        var selection = OutputSelection(requestedUID: wireless.uid)
        selection.update([speaker, wireless])
        guard selection.isAvailable else { return false }
        selection.update([speaker])
        guard !selection.isAvailable && selection.selectedDevice == nil
                && selection.requestedUID == wireless.uid else { return false }
        selection.update([speaker, wireless])
        return selection.isAvailable && selection.selectedDevice?.uid == wireless.uid
    }
    check("Missing output suspends retries while retaining the station") {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.setOutputAvailable(false, now: 1)
        return !intent.shouldPlay && intent.station == first
            && intent.retry(now: 60, health: failed) == nil
            && intent.retry(now: 120, health: PlaybackHealth(waiting: true)) == nil
    }
    check("Station changes remain suspended while the requested output is missing") {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.setOutputAvailable(false, now: 1)
        intent.select(second, now: 2)
        guard intent.station == second && !intent.shouldPlay
                && intent.retry(now: 60, health: failed) == nil else { return false }
        intent.setOutputAvailable(true, now: 61)
        return intent.shouldPlay && intent.station == second
    }
    check("Stop while an output is missing prevents playback when it returns") {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.setOutputAvailable(false, now: 1)
        intent.stop(now: 2)
        intent.setOutputAvailable(true, now: 60)
        return intent.station == nil && !intent.shouldPlay && intent.retry(now: 61, health: failed) == nil
    }
    check("Wake keeps playback suspended until the requested output returns") {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.setOutputAvailable(false, now: 1)
        intent.sleep()
        intent.wake(now: 60)
        guard intent.station == first && !intent.shouldPlay
                && intent.retry(now: 61, health: failed) == nil else { return false }
        intent.setOutputAvailable(true, now: 62)
        return intent.shouldPlay && intent.station == first
    }
    check("A returning output does not bypass sleep") {
        var intent = PlaybackIntent(now: 0)
        intent.select(first, now: 0)
        intent.setOutputAvailable(false, now: 1)
        intent.sleep()
        intent.setOutputAvailable(true, now: 2)
        guard !intent.shouldPlay && intent.station == first else { return false }
        intent.wake(now: 60)
        return intent.shouldPlay && intent.station == first
    }
    check("Requested output survives station changes and recovery") {
        var selection = OutputSelection(requestedUID: wireless.uid)
        selection.update([speaker, wireless])
        var intent = PlaybackIntent(now: 0)
        intent.setOutputAvailable(selection.isAvailable, now: 0)
        intent.select(first, now: 0)
        intent.select(second, now: 1)
        guard intent.retry(now: 2, health: failed) == .failed else { return false }
        intent.didStart(now: 2)
        guard intent.retry(now: 3, health: failed) == nil else { return false }
        return intent.retry(now: 32, health: failed) == .failed
            && intent.station == second && intent.shouldPlay
            && selection.requestedUID == wireless.uid && selection.selectedDevice?.uid == wireless.uid
    }
    print("\(checks) output checks, \(failures) failures")
    return failures
}
