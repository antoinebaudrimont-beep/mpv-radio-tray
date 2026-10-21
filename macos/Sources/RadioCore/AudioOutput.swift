import Foundation

public struct AudioDeviceRecord: Equatable {
    public let name: String?
    public let uid: String?
    public let outputChannels: UInt32
    public let transportType: UInt32?
    public let isAlive: Bool

    public init(name: String?, uid: String?, outputChannels: UInt32,
                transportType: UInt32?, isAlive: Bool = true) {
        self.name = name
        self.uid = uid
        self.outputChannels = outputChannels
        self.transportType = transportType
        self.isAlive = isAlive
    }
}

public struct AudioOutputDevice: Equatable {
    public let name: String
    public let uid: String
    public let transportType: UInt32?

    /// Classifies records using public CoreAudio metadata, without device-name or UID patterns.
    public static func exclusionReason(for record: AudioDeviceRecord) -> String? {
        guard record.isAlive else { return "device is unavailable" }
        guard record.outputChannels > 0 else { return "no output channels" }
        guard let uid = record.uid, !uid.isEmpty else { return "missing device UID" }
        switch record.transportType {
        // kAudioDeviceTransportTypeVirtual ('virt') and kAudioDeviceTransportTypeAirPlay ('airp').
        // Keep this model independent of CoreAudio so its classification is testable separately.
        case 0x76697274: return "virtual software device"
        case 0x61697270: return "AirPlay uses the native route picker"
        default: return nil
        }
    }

    public static func available(from records: [AudioDeviceRecord]) -> [AudioOutputDevice] {
        var seen = Set<String>()
        return records.compactMap { record in
            guard exclusionReason(for: record) == nil, let uid = record.uid,
                  seen.insert(uid).inserted else { return nil }
            let name = record.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AudioOutputDevice(name: name?.isEmpty == false ? name! : "Audio output",
                                     uid: uid, transportType: record.transportType)
        }.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.uid < $1.uid : comparison == .orderedAscending
        }
    }
}

// Tracks requested routing. A missing device keeps its preference; the playback
// controller suspends audio until it returns or the user chooses another output.
public struct OutputSelection {
    public private(set) var requestedUID: String?
    public private(set) var devices: [AudioOutputDevice] = []
    public var isAvailable: Bool { requestedUID == nil || devices.contains { $0.uid == requestedUID } }
    public var selectedDevice: AudioOutputDevice? { devices.first { $0.uid == requestedUID } }

    public init(requestedUID: String? = nil) {
        self.requestedUID = requestedUID?.isEmpty == false ? requestedUID : nil
    }
    public mutating func select(_ uid: String?) {
        requestedUID = uid?.isEmpty == false ? uid : nil
    }
    public mutating func update(_ records: [AudioDeviceRecord]) {
        devices = AudioOutputDevice.available(from: records)
    }
}
