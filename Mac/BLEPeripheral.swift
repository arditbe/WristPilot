import CoreBluetooth
import Foundation

/// Advertises the WristPilot service so the watch can find this Mac, send packets and read settings.
/// Callbacks, `onPacket` and `publish` run on the queue passed to `init`.
final class BLEPeripheral: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isAdvertising = false

    var onPacket: (Packet) -> Void = { _ in }

    private var manager: CBPeripheralManager!
    private var configCharacteristic: CBMutableCharacteristic?
    private var config = WatchConfig()
    private var configPending = false
    private var tunedCentrals: Set<UUID> = []

    init(queue: DispatchQueue) {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    /// Sends gesture settings to the watch. Call on the Bluetooth queue.
    func publish(_ config: WatchConfig) {
        self.config = config
        pushConfig()
    }

    private func pushConfig() {
        guard let configCharacteristic else { return }
        configPending = !manager.updateValue(config.encode(), for: configCharacteristic, onSubscribedCentrals: nil)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if configPending { pushConfig() }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        DispatchQueue.main.async {
            self.bluetoothState = state
            if state != .poweredOn { self.isAdvertising = false }
        }
        guard state == .poweredOn else { return }
        tunedCentrals.removeAll()
        let input = CBMutableCharacteristic(type: PilotLink.inputUUID,
                                            properties: [.write, .writeWithoutResponse],
                                            value: nil,
                                            permissions: [.writeable])
        let config = CBMutableCharacteristic(type: PilotLink.configUUID,
                                             properties: [.read, .notify],
                                             value: nil,
                                             permissions: [.readable])
        configCharacteristic = config
        let service = CBMutableService(type: PilotLink.serviceUUID, primary: true)
        service.characteristics = [input, config]
        peripheral.removeAllServices()
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: Host.current().localizedName ?? "Mac",
            CBAdvertisementDataServiceUUIDsKey: [PilotLink.serviceUUID],
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        let advertising = error == nil
        DispatchQueue.main.async { self.isAdvertising = advertising }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            tune(request.central)
            if let value = request.value, let packet = Packet.decode(value) { onPacket(packet) }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == PilotLink.configUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        let value = config.encode()
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        tune(central)
        pushConfig()
    }

    /// Shortest connection interval, so motion arrives with as little delay as possible.
    private func tune(_ central: CBCentral) {
        if tunedCentrals.insert(central.identifier).inserted {
            manager.setDesiredConnectionLatency(.low, for: central)
        }
    }
}
