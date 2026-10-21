import CoreAudio
import Foundation
import RadioCore

protocol AudioOutputDiscovery: AnyObject {
    func enumerate() throws -> [AudioDeviceRecord]
    func start(onChange: @escaping () -> Void)
    func shutdown()
}
extension CoreAudioOutputs: AudioOutputDiscovery {}

// Main-thread owner of the device inventory and the user's requested output.
final class OutputController {
    private static let uidKey = "audioOutputDeviceUID"
    private static let nameKey = "audioOutputDeviceName"
    private let discovery: AudioOutputDiscovery
    private let defaults: UserDefaults
    private let logger: RadioLogger
    private(set) var selection: OutputSelection
    private(set) var unavailableName: String
    private(set) var errorMessage: String?
    var onChange: (() -> Void)?

    init(logger: RadioLogger, defaults: UserDefaults = .standard, discovery: AudioOutputDiscovery? = nil) {
        self.logger = logger
        self.defaults = defaults
        self.discovery = discovery ?? CoreAudioOutputs(logger: logger)
        selection = OutputSelection(requestedUID: defaults.string(forKey: Self.uidKey))
        unavailableName = defaults.string(forKey: Self.nameKey) ?? "Saved output"
    }

    func start() {
        discovery.start { [weak self] in self?.refresh(reason: "device change") }
        refresh(reason: "startup")
    }

    func refresh(reason: String = "menu opened") {
        let oldUID = selection.requestedUID
        let oldDevices = selection.devices
        let oldAvailable = selection.isAvailable
        let oldError = errorMessage
        do {
            let records = try discovery.enumerate()
            if let uid = selection.requestedUID,
               let saved = records.first(where: { $0.uid == uid }),
               saved.transportType == kAudioDeviceTransportTypeVirtual || saved.transportType == kAudioDeviceTransportTypeAirPlay {
                selection.select(nil)
                defaults.removeObject(forKey: Self.uidKey)
                defaults.removeObject(forKey: Self.nameKey)
                unavailableName = "Saved output"
                logger.write("Saved output excluded by transport policy; using System Default")
            }
            selection.update(records)
            errorMessage = nil
        } catch {
            selection.update([])
            errorMessage = "Unable to list audio outputs — try Refresh Outputs"
            if oldError == nil { logger.write("Output enumeration failed") }
        }
        if let device = selection.selectedDevice {
            unavailableName = device.name
            defaults.set(device.name, forKey: Self.nameKey)
        }
        if oldAvailable != selection.isAvailable {
            logger.write(selection.isAvailable ? "Requested output available" : "Requested output unavailable; playback suspended")
        }
        if oldUID != selection.requestedUID || oldDevices != selection.devices || oldAvailable != selection.isAvailable || oldError != errorMessage {
            logger.write("Outputs refreshed: \(selection.devices.count); reason=\(reason)")
            onChange?()
        }
    }

    func select(_ uid: String?) {
        if let device = selection.devices.first(where: { $0.uid == uid }) {
            unavailableName = device.name
            defaults.set(device.name, forKey: Self.nameKey)
        }
        selection.select(uid)
        if let uid = selection.requestedUID {
            defaults.set(uid, forKey: Self.uidKey)
        } else {
            defaults.removeObject(forKey: Self.uidKey)
            defaults.removeObject(forKey: Self.nameKey)
            unavailableName = "Saved output"
        }
        // Revalidate at selection time in case the device vanished during menu tracking.
        refresh(reason: "selection")
        logger.write(selection.requestedUID == nil ? "Output selected: System Default" : "Output selected: \(selection.selectedDevice?.name ?? unavailableName)")
        onChange?()
    }

    func shutdown() {
        onChange = nil
        discovery.shutdown()
    }
}
