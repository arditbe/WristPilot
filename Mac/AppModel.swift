import AppKit
import ApplicationServices
import Combine
import os
import ServiceManagement

/// Connects the Bluetooth link to the mouse and keeps status for the menu.
/// Packets and mouse events run on `queue`. Published state changes on the main thread.
final class AppModel: ObservableObject {
    let settings = MacSettings()
    let link: BLEPeripheral

    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var watchConnected = false
    @Published private(set) var watchPaused = false
    @Published private(set) var lastEvent: String?
    /// Link quality summary, refreshed every second while the watch is connected.
    @Published private(set) var linkStats: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            if launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    private let queue = DispatchQueue(label: "wristpilot.mouse", qos: .userInteractive)
    private let mouse: MouseController
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    // Only touched on `queue`.
    private var lastHeard = Date.distantPast
    private var connected = false
    private var paused = false
    private var lastMotionAt: TimeInterval = 0
    private var motionGaps: [TimeInterval] = []
    private var watchConfig = WatchConfig()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WristPilot", category: "link")

    init() {
        mouse = MouseController(queue: queue)
        link = BLEPeripheral(queue: queue)
        let config = settings.mouseConfig
        let watchConfig = settings.watchConfig
        queue.async {
            self.mouse.config = config
            self.watchConfig = watchConfig
            self.link.publish(watchConfig)
        }

        link.onPacket = { [weak self] in self?.handle($0) }
        // Forward Bluetooth state changes so the menu refreshes.
        link.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        // objectWillChange fires before the value is stored, so read it on the next run loop pass.
        settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            guard let self else { return }
            let config = self.settings.mouseConfig
            let watchConfig = self.settings.watchConfig
            self.queue.async {
                self.mouse.config = config
                if !config.enabled { self.mouse.releaseAll() }
                if watchConfig != self.watchConfig {
                    self.watchConfig = watchConfig
                    self.link.publish(watchConfig)
                }
            }
        }.store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        if !accessibilityGranted { requestAccessibility() }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted { accessibilityGranted = trusted }
        queue.async {
            guard self.connected, Date().timeIntervalSince(self.lastHeard) > 3 else { return }
            self.connected = false
            self.mouse.releaseAll()
            DispatchQueue.main.async { self.watchConnected = false }
        }
    }

    private func handle(_ packet: Packet) {
        lastHeard = Date()
        if !connected {
            connected = true
            DispatchQueue.main.async { self.watchConnected = true }
        }

        switch packet {
        case let .motion(dx, dy, duration, held):
            let now = ProcessInfo.processInfo.systemUptime
            // Gaps over 100 ms are the hand stopping, not the link.
            if now - lastMotionAt < 0.1 { motionGaps.append(now - lastMotionAt) }
            lastMotionAt = now
            if mouse.config.enabled { mouse.addMotion(dx: dx, dy: dy, duration: duration, held: held) }
        case let .scroll(delta):
            if mouse.config.enabled { mouse.scroll(crown: delta) }
        case let .pinchScroll(dx, dy):
            if mouse.config.enabled { mouse.scroll(pinchDX: dx, dy: dy) }
        case let .gesture(gesture, age):
            guard mouse.config.enabled else { return }
            let action = gesture == .pinch ? mouse.config.pinchAction : mouse.config.doublePinchAction
            mouse.perform(action, age: Double(age) / 1000)
            report(gesture.title)
        case let .button(button):
            guard mouse.config.enabled else { return }
            mouse.click(button == .leftClick ? .left : .right)
            report(button == .leftClick ? "Watch: click" : "Watch: right click")
        case let .status(isPaused):
            guard isPaused != paused else { return }
            paused = isPaused
            if isPaused { mouse.releaseAll() }
            DispatchQueue.main.async { self.watchPaused = isPaused }
        case let .diagnostics(sampleRate, motionLag, motionLagMax, roundTrip, background):
            reportLatency(sampleRate: Int(sampleRate), motionLag: Int(motionLag), motionLagMax: Int(motionLagMax),
                          roundTrip: Int(roundTrip), background: background)
        }
    }

    private func reportLatency(sampleRate: Int, motionLag: Int, motionLagMax: Int, roundTrip: Int, background: Bool) {
        let gaps = motionGaps.sorted()
        motionGaps.removeAll()
        let packets = gaps.count
        let averageGap = gaps.isEmpty ? 0 : Int(gaps.reduce(0, +) / Double(gaps.count) * 1000)
        let worstGap = Int((gaps.last ?? 0) * 1000)
        let summary = "\(packets) packets/s, gap \(averageGap)/\(worstGap) ms, sensor \(sampleRate) Hz "
            + "(\(motionLag)/\(motionLagMax) ms), RTT \(roundTrip) ms, background \(background ? "on" : "off")"
        log.notice("\(summary, privacy: .public)")
        DispatchQueue.main.async { self.linkStats = summary }
    }

    private func report(_ event: String) {
        DispatchQueue.main.async { self.lastEvent = event }
    }
}
