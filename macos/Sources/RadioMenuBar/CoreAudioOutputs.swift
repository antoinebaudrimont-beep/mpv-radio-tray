import CoreAudio
import Foundation
import RadioCore

/// Reads available outputs and observes changes without changing any system audio setting.
final class CoreAudioOutputs {
    private struct ListenerKey: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope

        var address: AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                       mElement: kAudioObjectPropertyElementMain)
        }
    }

    private struct InventoryEntry: Equatable {
        let object: AudioObjectID
        let name: String?
        let uid: String?
        let outputChannels: UInt32
        let transport: UInt32?
        let isAlive: Bool
    }

    private enum InventoryError: LocalizedError {
        case property(OSStatus)
        case invalidSize

        var errorDescription: String? {
            switch self {
            case .property(let status): return "Cannot read audio devices (CoreAudio \(status))."
            case .invalidSize: return "CoreAudio returned an invalid audio-device list."
            }
        }
    }

    private let logger: RadioLogger
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var listeners: [ListenerKey: AudioObjectPropertyListenerBlock] = [:]
    private var lastInventory: [InventoryEntry]?
    private var onChange: (() -> Void)?
    private var pendingRefresh: DispatchWorkItem?
    private var isRunning = false

    init(logger: RadioLogger) {
        self.logger = logger
    }

    func enumerate() throws -> [AudioDeviceRecord] {
        precondition(Thread.isMainThread)
        let devices = try deviceIDs()
        if isRunning { updateDeviceListeners(devices) }
        let inventory = devices.map { device in
            InventoryEntry(object: device,
                           name: stringProperty(device, selector: kAudioObjectPropertyName),
                           uid: stringProperty(device, selector: kAudioDevicePropertyDeviceUID),
                           outputChannels: outputChannels(device),
                           transport: uintProperty(device, selector: kAudioDevicePropertyTransportType),
                           isAlive: uintProperty(device, selector: kAudioDevicePropertyDeviceIsAlive) == 1)
        }.sorted { $0.object < $1.object }
        logIfChanged(inventory)
        return inventory.map {
            AudioDeviceRecord(name: $0.name, uid: $0.uid, outputChannels: $0.outputChannels,
                              transportType: $0.transport, isAlive: $0.isAlive)
        }
    }

    func start(onChange: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        self.onChange = onChange
        guard !isRunning else { return }
        isRunning = true
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            addListener(ListenerKey(object: systemObject, selector: selector,
                                    scope: kAudioObjectPropertyScopeGlobal))
        }
        do { _ = try enumerate() }
        catch { logger.write(error.localizedDescription) }
    }

    func shutdown() {
        precondition(Thread.isMainThread)
        isRunning = false
        onChange = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        removeListeners()
    }

    deinit {
        pendingRefresh?.cancel()
        removeListeners()
    }

    private func deviceIDs() throws -> [AudioObjectID] {
        var address = ListenerKey(object: systemObject, selector: kAudioHardwarePropertyDevices,
                                  scope: kAudioObjectPropertyScopeGlobal).address
        // A device may connect between the size and data reads. Retry that short race.
        for attempt in 0..<3 {
            var size: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size)
            guard sizeStatus == noErr else { throw InventoryError.property(sizeStatus) }
            let stride = MemoryLayout<AudioObjectID>.stride
            guard Int(size) % stride == 0 else { throw InventoryError.invalidSize }
            guard size > 0 else { return [] }
            var devices = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
            let status = devices.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
                return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, base)
            }
            if status == kAudioHardwareBadPropertySizeError, attempt < 2 { continue }
            guard status == noErr else { throw InventoryError.property(status) }
            guard Int(size) % stride == 0, Int(size) / stride <= devices.count else {
                throw InventoryError.invalidSize
            }
            return Array(devices.prefix(Int(size) / stride))
        }
        throw InventoryError.invalidSize
    }

    private func stringProperty(_ device: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> String? {
        var address = ListenerKey(object: device, selector: selector,
                                  scope: kAudioObjectPropertyScopeGlobal).address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        // CoreAudio transfers ownership of these returned CFStrings to the caller.
        let string = value?.takeRetainedValue()
        guard status == noErr, let string else { return nil }
        return string as String
    }

    private func uintProperty(_ device: AudioObjectID,
                              selector: AudioObjectPropertySelector) -> UInt32? {
        var address = ListenerKey(object: device, selector: selector,
                                  scope: kAudioObjectPropertyScopeGlobal).address
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr, size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private func outputChannels(_ device: AudioObjectID) -> UInt32 {
        var address = ListenerKey(object: device, selector: kAudioDevicePropertyStreamConfiguration,
                                  scope: kAudioObjectPropertyScopeOutput).address
        guard AudioObjectHasProperty(device, &address) else { return 0 }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let capacity = max(Int(size), MemoryLayout<AudioBufferList>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity,
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr,
              Int(size) <= capacity else { return 0 }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let headerSize = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        guard Int(size) >= headerSize,
              Int(list.pointee.mNumberBuffers) <= (Int(size) - headerSize) / MemoryLayout<AudioBuffer>.stride
        else { return 0 }
        let channels = UnsafeMutableAudioBufferListPointer(list).reduce(UInt64(0)) {
            $0 + UInt64($1.mNumberChannels)
        }
        return UInt32(min(channels, UInt64(UInt32.max)))
    }

    private func updateDeviceListeners(_ devices: [AudioObjectID]) {
        var desired = Set<ListenerKey>()
        for device in devices {
            for selector in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceUID,
                             kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyTransportType] {
                desired.insert(ListenerKey(object: device, selector: selector,
                                           scope: kAudioObjectPropertyScopeGlobal))
            }
            for selector in [kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyStreams] {
                desired.insert(ListenerKey(object: device, selector: selector,
                                           scope: kAudioObjectPropertyScopeOutput))
            }
        }
        desired = desired.filter { key in
            var address = key.address
            return AudioObjectHasProperty(key.object, &address)
        }
        for key in Array(listeners.keys) where key.object != systemObject && !desired.contains(key) {
            removeListener(key)
        }
        for key in desired { addListener(key) }
    }

    private func addListener(_ key: ListenerKey) {
        guard listeners[key] == nil else { return }
        var address = key.address
        guard AudioObjectHasProperty(key.object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
        let status = AudioObjectAddPropertyListenerBlock(key.object, &address, .main, block)
        if status == noErr { listeners[key] = block }
        else { logger.write("Audio change listener unavailable (CoreAudio \(status))") }
    }

    private func removeListener(_ key: ListenerKey) {
        guard let block = listeners.removeValue(forKey: key) else { return }
        var address = key.address
        _ = AudioObjectRemovePropertyListenerBlock(key.object, &address, .main, block)
    }

    private func removeListeners() {
        for key in Array(listeners.keys) { removeListener(key) }
    }

    private func scheduleRefresh() {
        precondition(Thread.isMainThread)
        guard isRunning, pendingRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            guard self.isRunning else { return }
            do { _ = try self.enumerate() }
            catch { self.logger.write(error.localizedDescription) }
            self.onChange?()
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func logIfChanged(_ inventory: [InventoryEntry]) {
        guard inventory != lastInventory else { return }
        lastInventory = inventory
        logger.write("Audio inventory changed: \(inventory.count) devices")
        var includedUIDs = Set<String>()
        for entry in inventory {
            let name = String((entry.name ?? "Unnamed audio device").components(separatedBy: .newlines)
                .joined(separator: " ").prefix(120))
            let uidState = entry.uid?.isEmpty == false ? "present" : "missing"
            let transport = entry.transport.map {
                "\(transportDescription($0)) (\(String(format: "0x%08X", $0)))"
            } ?? "unknown"
            let record = AudioDeviceRecord(name: entry.name, uid: entry.uid,
                                           outputChannels: entry.outputChannels,
                                           transportType: entry.transport, isAlive: entry.isAlive)
            var reason = AudioOutputDevice.exclusionReason(for: record)
            if reason == nil, let uid = entry.uid, !includedUIDs.insert(uid).inserted {
                reason = "duplicate device UID"
            }
            let decision = reason.map { "excluded (\($0))" } ?? "included (available output)"
            logger.write("Audio device: \(name); UID=\(uidState); outputChannels=\(entry.outputChannels); transport=\(transport); alive=\(entry.isAlive); \(decision)")
        }
    }

    private func transportDescription(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        default: return String(format: "0x%08X", transport)
        }
    }
}
