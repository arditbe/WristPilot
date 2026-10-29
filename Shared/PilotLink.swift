import CoreBluetooth
import Foundation

/// Bluetooth LE service shared by the watch (central) and the Mac (peripheral).
enum PilotLink {
    static let serviceUUID = CBUUID(string: "8E7C1A20-5B3D-4C6E-9F1A-2B3C4D5E6F70")
    /// The watch writes every packet here.
    static let inputUUID = CBUUID(string: "8E7C1A21-5B3D-4C6E-9F1A-2B3C4D5E6F70")
    /// The Mac publishes gesture settings here (read + notify).
    static let configUUID = CBUUID(string: "8E7C1A22-5B3D-4C6E-9F1A-2B3C4D5E6F70")
}

enum HandGesture: UInt8, CaseIterable {
    case pinch = 1
    case doublePinch = 4

    var title: String {
        switch self {
        case .pinch: return "Pinch"
        case .doublePinch: return "Double pinch"
        }
    }
}

/// Buttons on the watch screen. They always mean the same thing on the Mac.
enum WatchButton: UInt8 {
    case leftClick = 1
    case rightClick = 2
}

/// Mac settings that change how the watch interprets gestures.
struct WatchConfig: Equatable {
    var pinchScroll = true
    /// When double pinch is in use, a single pinch has to wait a moment before it can fire.
    var doublePinch = true
    var haptics = true

    func encode() -> Data {
        Data([1, (pinchScroll ? 1 : 0) | (doublePinch ? 2 : 0) | (haptics ? 4 : 0)])
    }

    static func decode(_ data: Data) -> WatchConfig? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 1 else { return nil }
        return WatchConfig(pinchScroll: bytes[1] & 1 != 0, doublePinch: bytes[1] & 2 != 0, haptics: bytes[1] & 4 != 0)
    }
}

enum Packet: Equatable {
    /// Change in pointing direction in radians (x right, y down) and the milliseconds it covers.
    /// Sent continuously while tracking, so a gap on the Mac means the radio stalled.
    /// `held` is set while the watch keeps the cursor still around a gesture.
    case motion(dx: Float, dy: Float, duration: UInt8, held: Bool)
    /// `age` is how long ago (ms) the gesture started, so the click lands where the cursor was then.
    case gesture(HandGesture, age: UInt16)
    /// Digital Crown rotation.
    case scroll(Float)
    /// Pinch-and-tilt scrolling, in radians.
    case pinchScroll(dx: Float, dy: Float)
    case button(WatchButton)
    /// Heartbeat, also sent when tracking is paused or resumed.
    case status(paused: Bool)
    /// Once a second: sensor rate, sensor delay (avg/max ms), heartbeat round trip (ms), background state.
    case diagnostics(sampleRate: UInt8, motionLag: UInt8, motionLagMax: UInt8, roundTrip: UInt16, background: Bool)

    func encode() -> Data {
        var data = Data()
        switch self {
        case let .motion(dx, dy, duration, held):
            data.append(1)
            data.appendFloat(dx)
            data.appendFloat(dy)
            data.append(contentsOf: [duration, held ? 1 : 0])
        case let .gesture(gesture, age):
            data.append(contentsOf: [2, gesture.rawValue, UInt8(age & 0xFF), UInt8(age >> 8)])
        case let .scroll(delta):
            data.append(3)
            data.appendFloat(delta)
        case let .pinchScroll(dx, dy):
            data.append(7)
            data.appendFloat(dx)
            data.appendFloat(dy)
        case let .button(button):
            data.append(contentsOf: [4, button.rawValue])
        case let .status(paused):
            data.append(contentsOf: [5, paused ? 1 : 0])
        case let .diagnostics(sampleRate, motionLag, motionLagMax, roundTrip, background):
            data.append(contentsOf: [6, sampleRate, motionLag, motionLagMax,
                                     UInt8(roundTrip & 0xFF), UInt8(roundTrip >> 8), background ? 1 : 0])
        }
        return data
    }

    static func decode(_ data: Data) -> Packet? {
        let bytes = [UInt8](data)
        guard let type = bytes.first else { return nil }
        switch type {
        case 1:
            guard bytes.count >= 11, let dx = bytes.float(at: 1), let dy = bytes.float(at: 5) else { return nil }
            return .motion(dx: dx, dy: dy, duration: bytes[9], held: bytes[10] != 0)
        case 2:
            guard bytes.count >= 4, let gesture = HandGesture(rawValue: bytes[1]) else { return nil }
            return .gesture(gesture, age: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
        case 3:
            return bytes.float(at: 1).map(Packet.scroll)
        case 4:
            guard bytes.count >= 2, let button = WatchButton(rawValue: bytes[1]) else { return nil }
            return .button(button)
        case 5:
            guard bytes.count >= 2 else { return nil }
            return .status(paused: bytes[1] != 0)
        case 6:
            guard bytes.count >= 7 else { return nil }
            return .diagnostics(sampleRate: bytes[1], motionLag: bytes[2], motionLagMax: bytes[3],
                                roundTrip: UInt16(bytes[4]) | UInt16(bytes[5]) << 8, background: bytes[6] != 0)
        case 7:
            guard let dx = bytes.float(at: 1), let dy = bytes.float(at: 5) else { return nil }
            return .pinchScroll(dx: dx, dy: dy)
        default:
            return nil
        }
    }
}

private extension Data {
    mutating func appendFloat(_ value: Float) {
        Swift.withUnsafeBytes(of: value.bitPattern.littleEndian) { append(contentsOf: $0) }
    }
}

private extension Array where Element == UInt8 {
    func float(at index: Int) -> Float? {
        guard count >= index + 4 else { return nil }
        let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[index + $1]) << (8 * $1) }
        return Float(bitPattern: bits)
    }
}
