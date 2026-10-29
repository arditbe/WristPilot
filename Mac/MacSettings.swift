import Foundation

enum MouseAction: String, CaseIterable, Identifiable {
    case leftClick, rightClick, doubleClick, middleClick, toggleDrag, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftClick: return "Left click"
        case .rightClick: return "Right click"
        case .doubleClick: return "Double click"
        case .middleClick: return "Middle click"
        case .toggleDrag: return "Grab / release (drag)"
        case .none: return "Nothing"
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class MacSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    /// Points per radian when moving slowly.
    @Published var precision: Double { didSet { defaults.set(precision, forKey: "precision") } }
    /// Points per radian when moving fast.
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed") } }
    @Published var steadiness: Double { didSet { defaults.set(steadiness, forKey: "steadiness") } }
    /// Milliseconds over which late Bluetooth data is blended in.
    @Published var smoothing: Double { didSet { defaults.set(smoothing, forKey: "smoothing") } }
    @Published var invertX: Bool { didSet { defaults.set(invertX, forKey: "invertX") } }
    @Published var invertY: Bool { didSet { defaults.set(invertY, forKey: "invertY") } }
    @Published var crownScrollSpeed: Double { didSet { defaults.set(crownScrollSpeed, forKey: "scrollSpeed") } }
    @Published var pinchScroll: Bool { didSet { defaults.set(pinchScroll, forKey: "pinchScroll") } }
    @Published var pinchScrollSpeed: Double { didSet { defaults.set(pinchScrollSpeed, forKey: "pinchScrollSpeed") } }
    @Published var invertScroll: Bool { didSet { defaults.set(invertScroll, forKey: "invertScroll") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var pinchAction: MouseAction { didSet { defaults.set(pinchAction.rawValue, forKey: "pinchAction") } }
    @Published var doublePinchAction: MouseAction {
        didSet { defaults.set(doublePinchAction.rawValue, forKey: "doublePinchAction") }
    }

    init() {
        // Version 3 changed the movement model, so older speed settings no longer apply.
        if defaults.integer(forKey: "settingsVersion") < 3 {
            ["speed", "acceleration", "smoothing", "steadiness", "clenchAction"].forEach(defaults.removeObject(forKey:))
            defaults.set(3, forKey: "settingsVersion")
        }
        let tuning = PointerFilter.Tuning()
        defaults.register(defaults: [
            "enabled": true,
            "precision": tuning.precision,
            "speed": tuning.speed,
            "steadiness": tuning.steadiness,
            "smoothing": tuning.smoothing,
            "invertX": false,
            "invertY": false,
            "scrollSpeed": 60.0,
            "pinchScroll": true,
            "pinchScrollSpeed": 4000.0,
            "invertScroll": false,
            "haptics": true,
            "pinchAction": MouseAction.leftClick.rawValue,
            "doublePinchAction": MouseAction.rightClick.rawValue,
        ])
        enabled = defaults.bool(forKey: "enabled")
        precision = defaults.double(forKey: "precision")
        speed = defaults.double(forKey: "speed")
        steadiness = defaults.double(forKey: "steadiness")
        smoothing = defaults.double(forKey: "smoothing")
        invertX = defaults.bool(forKey: "invertX")
        invertY = defaults.bool(forKey: "invertY")
        crownScrollSpeed = defaults.double(forKey: "scrollSpeed")
        pinchScroll = defaults.bool(forKey: "pinchScroll")
        pinchScrollSpeed = defaults.double(forKey: "pinchScrollSpeed")
        invertScroll = defaults.bool(forKey: "invertScroll")
        haptics = defaults.bool(forKey: "haptics")
        pinchAction = MouseAction(rawValue: defaults.string(forKey: "pinchAction") ?? "") ?? .leftClick
        doublePinchAction = MouseAction(rawValue: defaults.string(forKey: "doublePinchAction") ?? "") ?? .rightClick
    }

    var mouseConfig: MouseController.Config {
        MouseController.Config(enabled: enabled,
                               tuning: PointerFilter.Tuning(precision: precision, speed: speed,
                                                            steadiness: steadiness, smoothing: smoothing),
                               invertX: invertX, invertY: invertY,
                               crownScrollSpeed: crownScrollSpeed, pinchScrollSpeed: pinchScrollSpeed,
                               invertScroll: invertScroll,
                               pinchAction: pinchAction, doublePinchAction: doublePinchAction)
    }

    var watchConfig: WatchConfig {
        WatchConfig(pinchScroll: pinchScroll, doublePinch: doublePinchAction != .none, haptics: haptics)
    }
}
