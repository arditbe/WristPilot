// Simulation tests for the motion and gesture code. They run on the Mac with synthetic sensor data.
// Usage: Scripts/test.sh

import Foundation
import simd

var failures = 0

func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS  " : "FAIL  ") + message)
    if !ok { failures += 1 }
}

func note(_ message: String) {
    print("      " + message)
}

/// Seeded generator so every run sees the same data.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

var rng = SplitMix64(state: 42)

func gauss(_ sigma: Double) -> Double {
    let u1 = Double.random(in: 1e-9..<1, using: &rng)
    let u2 = Double.random(in: 0..<1, using: &rng)
    return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
}

// MARK: Packets

let packets: [Packet] = [
    .motion(dx: 0.01, dy: -0.5, duration: 90, held: true), .gesture(.doublePinch, age: 1234), .scroll(-3.25),
    .pinchScroll(dx: 0, dy: 0.2), .button(.rightClick), .status(paused: true),
    .diagnostics(sampleRate: 100, motionLag: 5, motionLagMax: 40, roundTrip: 300, background: true),
]
check(packets.allSatisfy { Packet.decode($0.encode()) == $0 }, "every packet type survives encode/decode")
let config = WatchConfig(pinchScroll: false, doublePinch: true, haptics: false)
check(WatchConfig.decode(config.encode()) == config, "watch settings survive encode/decode")

// MARK: Pointing

/// Watch orientation for a forearm pointing forward and raised by `elevation`.
/// World axes: x right, y forward, z up. Watch x runs along the forearm, z out of the screen.
func watchFrame(elevation: Double) -> (toWorld: simd_double3x3, gravity: SIMD3<Double>) {
    let c = cos(elevation), s = sin(elevation)
    let x = SIMD3(0, c, s)
    let z = SIMD3(0, -s, c)
    let toWorld = simd_double3x3(columns: (x, simd_cross(z, x), z))
    return (toWorld, toWorld.transpose * SIMD3(0, 0, -1))
}

for degrees in [0.0, 30, 60] {
    let frame = watchFrame(elevation: degrees * .pi / 180)
    var pointer = PointerMath(towardHand: true)
    func rate(worldRotation: SIMD3<Double>) -> SIMD2<Double> {
        pointer.rate(rotation: frame.toWorld.transpose * worldRotation, gravity: frame.gravity)
    }
    let twist = rate(worldRotation: frame.toWorld.columns.0 * 2)
    let left = rate(worldRotation: SIMD3(0, 0, 1))
    let up = rate(worldRotation: SIMD3(1, 0, 0))
    check(simd_length(twist) < 1e-9, "arm at \(Int(degrees)) degrees: twisting the wrist does not move the cursor")
    check(left.x < -0.4 && abs(left.y) < 1e-9, "arm at \(Int(degrees)) degrees: turning left moves the cursor left")
    check(up.y < -0.9 && abs(up.x) < 1e-9, "arm at \(Int(degrees)) degrees: raising the arm moves the cursor up")
}

// MARK: Pinch detection

enum Kind: String {
    case pinch, release, swing, shake
}

/// Simulates `count` separate events and returns the windows each one triggered.
func events(of kind: Kind, count: Int, threshold: Double) -> [[[MotionSample]]] {
    var result: [[[MotionSample]]] = []
    var current: [[MotionSample]] = []
    let detector = GestureDetector(threshold: threshold)
    detector.onWindow = { window, _ in current.append(window) }
    var time = 0.0
    for _ in 0..<count {
        current = []
        let amp = Double.random(in: 0.7...1.3, using: &rng)
        for i in 0..<60 {
            time += 0.01
            var a = SIMD3(gauss(0.003), gauss(0.003), gauss(0.003))
            var w = SIMD3(gauss(0.02), gauss(0.02), gauss(0.02))
            let k = i - 25
            switch kind {
            case .pinch:
                // Sharp knock mostly along z, ringing once, little rotation.
                if k == 0 { a += SIMD3(0.02, -0.03, 0.18) * amp }
                if k == 1 { a += SIMD3(-0.01, 0.015, -0.09) * amp }
                if k == 0 || k == 1 { w += SIMD3(0.1, 0.05, 0.05) }
            case .release:
                // Weaker knock in another direction, slower ring.
                if k == 0 { a += SIMD3(0.07, 0.06, 0.01) * amp }
                if k == 1 { a += SIMD3(0.02, 0.03, 0.0) * amp }
                if k == 2 { a += SIMD3(-0.03, -0.02, 0.0) * amp }
            case .swing:
                // Fast arm movement with a jolt in the middle.
                let phase = Double(i) / 60 * 2 * .pi
                a += SIMD3(0.4 * sin(phase), 0.3 * cos(phase * 1.3), 0.1 * sin(phase * 2)) * amp
                w += SIMD3(2.5 * cos(phase), 1.0, 0.5)
                if k == 0 { a += SIMD3(0.12, 0.1, 0) * amp }
            case .shake:
                // Tremor-like shaking at 9 Hz.
                let phase = Double(i) * 0.01 * 9 * 2 * .pi
                a += SIMD3(0.3 * sin(phase), 0.25 * cos(phase), 0.1 * sin(phase)) * amp
                w += SIMD3(0.3 * sin(phase), 0.2 * cos(phase), 0.1)
            }
            detector.process(acceleration: a, rotation: w, time: time)
        }
        result.append(current)
    }
    return result
}

func strongest(_ windows: [[MotionSample]]) -> [MotionSample]? {
    windows.max { ($0.map(\.energy).max() ?? 0) < ($1.map(\.energy).max() ?? 0) }
}

// Train the way the watch does: the strongest knock of each pinch, everything from the other activities.
let trainingPinches = events(of: .pinch, count: 12, threshold: 0.02).compactMap(strongest)
let trainingNoise = (events(of: .release, count: 8, threshold: 0.02) + events(of: .swing, count: 8, threshold: 0.02)
    + events(of: .shake, count: 4, threshold: 0.02)).flatMap { $0 }
let model = GestureModel.train(pinches: trainingPinches, noise: trainingNoise)
let classifier = PinchClassifier(model: model)

func pinchCount(_ kind: Kind, threshold: Double) -> Int {
    events(of: kind, count: 200, threshold: threshold).filter { windows in
        windows.contains { classifier.classify(GestureAnalysis.features(of: $0, template: model.template)) == .pinch }
    }.count
}

for (label, threshold) in [("trained trigger", model.triggerThreshold), ("lowest trigger", 0.02)] {
    let pinches = pinchCount(.pinch, threshold: threshold)
    check(pinches >= 194, "\(label): \(pinches)/200 pinches recognised")
    for kind in [Kind.release, .swing, .shake] {
        let false_ = pinchCount(kind, threshold: threshold)
        check(false_ <= 4, "\(label): \(false_)/200 \(kind.rawValue) events taken as pinches")
    }
}

// MARK: Pointer filter

/// Feeds the filter like the watch and Bluetooth would (100 Hz samples, a 90 ms stall every second)
/// and returns the cursor path in points.
func run(_ tuning: PointerFilter.Tuning = .init(), seconds: Double, rate: (Double) -> SIMD2<Double>,
         held: (Double) -> Bool = { _ in false }) -> [SIMD2<Double>] {
    var filter = PointerFilter()
    filter.tuning = tuning
    var t = 0.0, sampleTime = 0.0
    var pending = SIMD2<Double>.zero, pendingSpan = 0.0, pendingHeld = false
    var position = SIMD2<Double>.zero
    var path: [SIMD2<Double>] = []
    while t < seconds {
        t += 0.004
        if t >= sampleTime + 0.01 {
            sampleTime += 0.01
            pending += rate(sampleTime) * 0.01
            pendingSpan += 0.01
            pendingHeld = pendingHeld || held(sampleTime)
            let inSecond = t.truncatingRemainder(dividingBy: 1)
            if !(inSecond > 0.5 && inSecond < 0.59) {
                filter.add(pending, span: pendingSpan, held: pendingHeld, now: t)
                pending = .zero
                pendingSpan = 0
                pendingHeld = false
            }
        }
        position += filter.step(now: t, dt: 0.004)
        path.append(position)
    }
    return path
}

func spread(_ path: [SIMD2<Double>]) -> Double {
    let xs = path.map(\.x), ys = path.map(\.y)
    return max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
}

// A hand held up in the air: 0.15 degree tremor at 9 Hz, slow drift, sensor noise.
let tremor: (Double) -> SIMD2<Double> = { t in
    let w = 2 * Double.pi * 9
    return SIMD2(0.0026 * w * cos(w * t), 0.0026 * w * sin(w * t * 1.1)) + SIMD2(0.005, -0.003)
        + SIMD2(gauss(0.01), gauss(0.01))
}

let still = spread(run(seconds: 4, rate: tremor))
let unlocked = spread(run(.init(precision: 700, speed: 9000, steadiness: 0, smoothing: 15), seconds: 4, rate: tremor))
check(still < 3, String(format: "hand held still: cursor moves %.1f pt (%.1f pt with Steadiness 0)", still, unlocked))

// The watch holds the cursor for a pinch, but a twitch just before the hold still gets through.
let pinchPath = run(seconds: 2, rate: { t in tremor(t) + (t > 1.0 && t < 1.03 ? SIMD2(0.3, -0.4) : .zero) },
                    held: { t in t >= 1.03 && t < 1.5 })
check(spread(pinchPath) < 4, String(format: "pinch while aiming: cursor moves %.1f pt", spread(pinchPath)))

for (degrees, seconds, label) in [(0.5, 0.15, "0.5 degree nudge"), (1.0, 0.25, "1 degree nudge"),
                                  (5.0, 0.6, "steady 5 degree turn"), (10.0, 0.15, "quick 10 degree flick")] {
    let r = degrees * .pi / 180 / seconds
    let path = run(seconds: seconds + 1, rate: { t in t > 0.3 && t < 0.3 + seconds ? SIMD2(r, 0) : .zero })
    note(String(format: "%@: %.0f pt", label, path.last!.x))
}

let sweep = run(seconds: 2.5, rate: { _ in SIMD2(1.0, 0) })
let speeds = (300..<sweep.count).map { (sweep[$0].x - sweep[$0 - 1].x) / 0.004 }
check(speeds.max()! / speeds.min()! < 1.2,
      String(format: "steady sweep through radio stalls: %.0f to %.0f pt/s", speeds.min()!, speeds.max()!))

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
