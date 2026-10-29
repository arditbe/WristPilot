import CoreBluetooth
import Foundation

/// Connects to the Mac, streams packets to it and receives its gesture settings.
final class BLEClient: NSObject, ObservableObject {
    enum Status: String {
        case off = "Bluetooth is off"
        case unauthorized = "Bluetooth not allowed"
        case searching = "Looking for your Mac"
        case connecting = "Connecting"
        case connected = "Connected"
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var macName: String?

    /// Called on the Bluetooth queue when the Mac's gesture settings arrive or change.
    var onConfig: (WatchConfig) -> Void = { _ in }

    private let queue = DispatchQueue(label: "wristpilot.ble", qos: .userInteractive)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var input: CBCharacteristic?
    private var pendingMotion = SIMD2<Double>.zero
    private var pendingDuration: TimeInterval = 0
    private var pendingHeld = false
    private var pendingScroll = SIMD2<Double>.zero
    private var paused = false
    private var heartbeat: DispatchSourceTimer?
    private var statusSentAt: TimeInterval?
    private var roundTrip: TimeInterval = 0
    private var sampleRate = 0
    private var motionLag = 0.0
    private var motionLagMax = 0.0
    private var background = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.sendStatus() }
        timer.resume()
        heartbeat = timer
    }

    /// Movement is accumulated and sent whenever the radio can take another packet.
    func addMotion(_ delta: SIMD2<Double>, duration: TimeInterval, held: Bool) {
        queue.async {
            guard self.input != nil else { return }
            self.pendingMotion += delta
            self.pendingDuration += duration
            self.pendingHeld = self.pendingHeld || held
            self.flush()
        }
    }

    func addScroll(_ delta: SIMD2<Double>) {
        queue.async {
            guard self.input != nil else { return }
            self.pendingScroll += delta
            self.flush()
        }
    }

    func send(_ packet: Packet, reliable: Bool = true) {
        queue.async {
            guard let peripheral = self.peripheral, let input = self.input else { return }
            peripheral.writeValue(packet.encode(), for: input, type: reliable ? .withResponse : .withoutResponse)
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            self.paused = paused
            self.pendingMotion = .zero
            self.pendingDuration = 0
            self.pendingHeld = false
            self.pendingScroll = .zero
            self.sendStatus()
        }
    }

    func updateDiagnostics(sampleRate: Int, motionLag: Double, motionLagMax: Double, background: Bool) {
        queue.async {
            self.sampleRate = sampleRate
            self.motionLag = motionLag
            self.motionLagMax = motionLagMax
            self.background = background
        }
    }

    private func sendStatus() {
        guard let peripheral, let input else { return }
        if statusSentAt == nil { statusSentAt = ProcessInfo.processInfo.systemUptime }
        peripheral.writeValue(Packet.status(paused: paused).encode(), for: input, type: .withResponse)
        let diagnostics = Packet.diagnostics(sampleRate: UInt8(min(sampleRate, 255)),
                                             motionLag: UInt8(min(motionLag * 1000, 255)),
                                             motionLagMax: UInt8(min(motionLagMax * 1000, 255)),
                                             roundTrip: UInt16(min(roundTrip * 1000, 65_535)),
                                             background: background)
        peripheral.writeValue(diagnostics.encode(), for: input, type: .withoutResponse)
    }

    private func flush() {
        guard let peripheral, let input else { return }
        if pendingDuration > 0, peripheral.canSendWriteWithoutResponse {
            let packet = Packet.motion(dx: Float(pendingMotion.x), dy: Float(pendingMotion.y),
                                       duration: UInt8(min(pendingDuration * 1000, 255).rounded()), held: pendingHeld)
            peripheral.writeValue(packet.encode(), for: input, type: .withoutResponse)
            pendingMotion = .zero
            pendingDuration = 0
            pendingHeld = false
        }
        if pendingScroll != .zero, peripheral.canSendWriteWithoutResponse {
            let packet = Packet.pinchScroll(dx: Float(pendingScroll.x), dy: Float(pendingScroll.y))
            peripheral.writeValue(packet.encode(), for: input, type: .withoutResponse)
            pendingScroll = .zero
        }
    }

    private func scan() {
        input = nil
        peripheral = nil
        statusSentAt = nil
        guard central.state == .poweredOn else { return }
        publish(.searching, name: nil)
        central.scanForPeripherals(withServices: [PilotLink.serviceUUID])
    }

    private func publish(_ status: Status, name: String?) {
        DispatchQueue.main.async {
            self.status = status
            self.macName = name
        }
    }
}

extension BLEClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scan()
        case .unauthorized: publish(.unauthorized, name: nil)
        default: publish(.off, name: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        publish(.connecting, name: name)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([PilotLink.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        scan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        scan()
    }
}

extension BLEClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == PilotLink.serviceUUID }) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([PilotLink.inputUUID, PilotLink.configUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let input = service.characteristics?.first(where: { $0.uuid == PilotLink.inputUUID }) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        self.input = input
        if let config = service.characteristics?.first(where: { $0.uuid == PilotLink.configUUID }) {
            peripheral.readValue(for: config)
            peripheral.setNotifyValue(true, for: config)
        }
        DispatchQueue.main.async { self.status = .connected }
        sendStatus()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == PilotLink.configUUID, let value = characteristic.value,
              let config = WatchConfig.decode(value) else { return }
        onConfig(config)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Acknowledged writes complete in order, which is close enough for a round-trip estimate.
        guard let sent = statusSentAt else { return }
        statusSentAt = nil
        roundTrip = ProcessInfo.processInfo.systemUptime - sent
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flush()
    }
}
