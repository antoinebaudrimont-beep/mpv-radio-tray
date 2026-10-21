import AppKit
import AVFoundation
import AVKit

final class AirPlayController: NSObject, AVRoutePickerViewDelegate, NSPopoverDelegate {
    private let logger: RadioLogger
    private let detector = AVRouteDetector()
    private let picker = AVRoutePickerView(frame: NSRect(x: 12, y: 12, width: 48, height: 40))
    private let popover = NSPopover()
    private var availabilityObserver: NSObjectProtocol?
    private var detectionTimeout: DispatchWorkItem?
    private var routesAvailable: Bool?
    private var presentingRoutes = false
    private var stopped = false

    var onAvailabilityChanged: (() -> Void)?
    var onWillPresentRoutes: (() -> Void)?
    var isPresented: Bool { popover.isShown }
    var menuTitle: String { routesAvailable == true ? "AirPlay… (routes available)" : "AirPlay…" }

    init(player: AVPlayer, logger: RadioLogger) {
        self.logger = logger
        super.init()

        picker.player = player
        picker.delegate = self
        picker.setAccessibilityLabel("AirPlay")

        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 72, height: 64))
        content.view.addSubview(picker)
        popover.contentViewController = content
        popover.contentSize = content.view.frame.size
        popover.behavior = .transient
        popover.delegate = self

        availabilityObserver = NotificationCenter.default.addObserver(
            forName: .AVRouteDetectorMultipleRoutesDetectedDidChange,
            object: detector,
            queue: .main
        ) { [weak self] _ in self?.updateAvailability() }
    }

    /// Detection is scoped to menu use because continuous discovery increases power use.
    func detectRoutes() {
        guard !stopped else { return }
        detectionTimeout?.cancel()
        detector.isRouteDetectionEnabled = true
        updateAvailability()
        guard !popover.isShown else { return }
        let timeout = DispatchWorkItem { [weak self] in self?.stopDetection() }
        detectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !stopped, button.window != nil, !popover.isShown else { return }
        detectRoutes()
        detectionTimeout?.cancel()
        detectionTimeout = nil
        popover.behavior = .transient
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if popover.isShown {
            logger.write("AirPlay control opened")
        } else {
            stopDetection()
            logger.write("AirPlay control could not be presented")
        }
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        guard !stopped, routePickerView === picker else { return }
        onWillPresentRoutes?()
        presentingRoutes = true
        // Apple's receiver list must not dismiss its own transient anchor.
        popover.behavior = .applicationDefined
        logger.write("Native AirPlay routes opened")
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        guard !stopped, routePickerView === picker else { return }
        presentingRoutes = false
        popover.behavior = .transient
        logger.write("Native AirPlay routes closed")
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, !self.presentingRoutes else { return }
            self.popover.performClose(nil)
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool { !presentingRoutes }

    func popoverDidClose(_ notification: Notification) {
        presentingRoutes = false
        popover.behavior = .transient
        stopDetection()
        logger.write("AirPlay control closed")
    }

    private func updateAvailability() {
        guard !stopped, detector.isRouteDetectionEnabled else { return }
        let available = detector.multipleRoutesDetected
        guard available != routesAvailable else { return }
        routesAvailable = available
        logger.write("AirPlay routes available=\(available)")
        onAvailabilityChanged?()
    }

    private func stopDetection() {
        detectionTimeout?.cancel()
        detectionTimeout = nil
        detector.isRouteDetectionEnabled = false
    }

    func dismiss() {
        guard !presentingRoutes else { return }
        popover.performClose(nil)
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        onAvailabilityChanged = nil
        onWillPresentRoutes = nil
        stopDetection()
        if let availabilityObserver {
            NotificationCenter.default.removeObserver(availabilityObserver)
            self.availabilityObserver = nil
        }
        picker.delegate = nil
        picker.player = nil
        popover.delegate = nil
        popover.close()
    }

    deinit {
        detectionTimeout?.cancel()
        if let availabilityObserver { NotificationCenter.default.removeObserver(availabilityObserver) }
    }
}
