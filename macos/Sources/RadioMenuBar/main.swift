import AppKit
import Darwin
import RadioCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let logger = RadioLogger()
    private lazy var controller = PlayerController(logger: logger)
    private lazy var outputs = OutputController(logger: logger)
    private lazy var airPlay = AirPlayController(player: controller.player, logger: logger)
    private var state = PlayerViewState()
    private var stations: [Station] = []
    private var configError: String?
    private var signals: [DispatchSourceSignal] = []
    private var shuttingDown = false
    private var menuOpen = false
    private var deferredMenuUpdate = false
    private let stationsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MPV Radio Tray/stations.txt")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menuIcon = NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "radio", accessibilityDescription: "MPV Radio Tray")
        menuIcon?.size = NSSize(width: 18, height: 18)
        menuIcon?.isTemplate = true
        menuIcon?.accessibilityDescription = "MPV Radio Tray"
        statusItem.button?.image = menuIcon
        statusItem.button?.toolTip = "MPV Radio Tray"
        menu.delegate = self
        statusItem.menu = menu
        controller.onChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            self.statusItem.button?.toolTip = state.message
            self.rebuildMenu()
        }
        outputs.onChange = { [weak self] in
            guard let self else { return }
            self.controller.selectOutput(uid: self.outputs.selection.requestedUID, available: self.outputs.selection.isAvailable)
            self.rebuildMenu()
        }
        airPlay.onAvailabilityChanged = { [weak self] in self?.rebuildMenu() }
        airPlay.onWillPresentRoutes = { [weak self] in self?.outputs.select(nil) }
        outputs.start()
        controller.selectOutput(uid: outputs.selection.requestedUID, available: outputs.selection.isAvailable)
        loadStations()
        rebuildMenu()
        airPlay.detectRoutes()
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        NSLog("MPV Radio Tray ready")
    }

    private func loadStations() {
        do {
            if !FileManager.default.fileExists(atPath: stationsFile.path) {
                try FileManager.default.createDirectory(at: stationsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/mpv-radio-tray/stations.txt")
                guard let source = FileManager.default.fileExists(atPath: legacy.path) ? legacy : Bundle.main.url(forResource: "stations", withExtension: "txt") else {
                    throw RadioError.message("Default stations missing. Build and open the .app bundle.")
                }
                try FileManager.default.copyItem(at: source, to: stationsFile)
            }
            let loaded = try Station.parse(String(contentsOf: stationsFile, encoding: .utf8))
            stations = loaded
            configError = nil
        } catch {
            // Retain the previous valid menu if an edit is malformed.
            configError = error.localizedDescription
        }
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, to targetMenu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = action != nil
        (targetMenu ?? menu).addItem(item)
        return item
    }

    private func rebuildMenu() {
        // Avoid rebuilding a menu while the user is tracking an item.
        if menuOpen { deferredMenuUpdate = true; return }
        menu.removeAllItems()
        menu.autoenablesItems = false
        add(state.message)
        if let configError { add(configError).toolTip = configError }
        menu.addItem(.separator())
        if stations.isEmpty { add("No stations configured") }
        for (index, station) in stations.enumerated() {
            let item = add(station.name, action: #selector(selectStation(_:)))
            item.tag = index
            item.state = station == state.station ? .on : .off
        }
        menu.addItem(.separator())
        let output = add("Output")
        output.isEnabled = true
        let outputMenu = NSMenu(title: "Output")
        output.submenu = outputMenu
        populateOutputMenu(outputMenu)
        let airPlayItem = add(airPlay.menuTitle, action: #selector(showAirPlay))
        airPlayItem.isEnabled = state.canSelectAirPlay
        airPlayItem.toolTip = state.canSelectAirPlay ? nil : "Play a station before choosing AirPlay"
        menu.addItem(.separator())
        if state.isPaused { add("Resume", action: #selector(resume)) }
        add("Stop", action: #selector(stop)).isEnabled = state.station != nil
        add("Edit Stations…", action: #selector(editStations))
        add("Reload Stations", action: #selector(reloadStations))
        add("Show Logs", action: #selector(showLogs))
        menu.addItem(.separator())
        let quit = add("Quit MPV Radio Tray", action: #selector(quit))
        quit.keyEquivalent = "q"
    }

    private func populateOutputMenu(_ outputMenu: NSMenu) {
        outputMenu.removeAllItems()
        outputMenu.autoenablesItems = false
        outputMenu.delegate = self
        let systemDefault = add("System Default", action: #selector(selectDefaultOutput), to: outputMenu)
        systemDefault.state = outputs.selection.requestedUID == nil ? .on : .off
        for device in outputs.selection.devices {
            let item = add(device.name, action: #selector(selectOutput(_:)), to: outputMenu)
            item.representedObject = device.uid
            item.state = device.uid == outputs.selection.requestedUID ? .on : .off
        }
        if !outputs.selection.isAvailable {
            add("\(outputs.unavailableName) (unavailable)", to: outputMenu).state = .on
        }
        if let message = outputs.errorMessage { add(message, to: outputMenu) }
        outputMenu.addItem(.separator())
        add("Refresh Outputs", action: #selector(refreshOutputs), to: outputMenu)
        add("Sound Settings…", action: #selector(soundSettings), to: outputMenu)
        add("Bluetooth Settings…", action: #selector(bluetoothSettings), to: outputMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        outputs.refresh()
        if menu === self.menu { airPlay.detectRoutes(); menuOpen = true }
        else { populateOutputMenu(menu) }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        if deferredMenuUpdate {
            deferredMenuUpdate = false
            DispatchQueue.main.async { [weak self] in self?.rebuildMenu() }
        }
    }

    @objc private func selectStation(_ item: NSMenuItem) { controller.play(stations[item.tag]) }
    @objc private func stop() { controller.stop() }
    @objc private func resume() { controller.resume() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showAirPlay() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.canSelectAirPlay, let button = self.statusItem.button else { return }
            if self.airPlay.isPresented { self.airPlay.dismiss() }
            else { self.airPlay.show(relativeTo: button) }
        }
    }
    @objc private func selectDefaultOutput() { outputs.select(nil) }
    @objc private func selectOutput(_ item: NSMenuItem) {
        if let uid = item.representedObject as? String { outputs.select(uid) }
    }
    @objc private func refreshOutputs() { outputs.refresh(reason: "manual refresh") }
    @objc private func reloadStations() { loadStations(); rebuildMenu() }
    @objc private func editStations() {
        NSWorkspace.shared.open([stationsFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func bluetoothSettings() { openSettings("Bluetooth") }
    @objc private func soundSettings() { openSettings("Sound") }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.\(pane)-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func showLogs() { NSWorkspace.shared.open(RadioLogger.directory) }
    @objc private func willSleep() { airPlay.dismiss(); controller.sleep() }
    @objc private func didWake() { outputs.refresh(reason: "wake"); controller.wake() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shuttingDown { return .terminateNow }
        shuttingDown = true
        airPlay.shutdown()
        outputs.shutdown()
        controller.shutdown()
        logger.close()
        return .terminateNow
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
