import Foundation
import simd

enum GestureLabel: String, Codable {
    case pinch, noise
}

struct MotionSample {
    var acceleration: SIMD3<Double>
    /// Second difference of acceleration. Keeps sharp knocks, drops smooth arm movement.
    var highPass: SIMD3<Double>
    var rotation: SIMD3<Double>
    var energy: Double
}

/// Describes the vibration around one candidate knock.
struct GestureFeatures: Codable {
    var peak: Double
    /// Peak over the window average. High for a single knock, low for shaking.
    var sharpness: Double
    var width: Double
    /// Log ratio of knock energy to overall movement energy.
    var highFrequency: Double
    var gyroPeak: Double
    /// Absolute direction of the knock. A person's pinch hits the watch the same way every time.
    var axisX: Double
    var axisY: Double
    var axisZ: Double
    /// Similarity (0 to 1) to the trained pinch waveform, 0 before training.
    var shape: Double

    var vector: [Double] {
        [log(peak + 1e-4), log(sharpness), width / 3, highFrequency, log(gyroPeak + 1e-2),
         axisX, axisY, axisZ, shape * 3]
    }

    static let weights: [Double] = [1, 1.5, 1, 1.2, 1, 0.7, 0.7, 0.7, 2]
}

enum GestureAnalysis {
    static let templateLength = 10

    static func peakIndex(_ window: [MotionSample]) -> Int {
        window.indices.max { window[$0].energy < window[$1].energy } ?? 0
    }

    static func features(of window: [MotionSample], template: [Double]?) -> GestureFeatures {
        // Centre on the peak so windows line up no matter how early the trigger fired.
        let peakAt = peakIndex(window)
        let core = window[max(0, peakAt - 4)..<min(window.count, peakAt + 7)]
        let count = Double(max(core.count, 1))
        let energies = core.map(\.energy)
        let peak = energies.max() ?? 0
        let mean = energies.reduce(0, +) / count
        let knock = core.map { simd_length_squared($0.highPass) }.reduce(0, +)
        let meanAcceleration = core.map(\.acceleration).reduce(SIMD3<Double>.zero, +) / count
        let movement = core.map { simd_length_squared($0.acceleration - meanAcceleration) }.reduce(0, +)
        let strongest = window.indices.contains(peakAt) ? window[peakAt].highPass : .zero
        let axis = simd_length(strongest) > 0 ? simd_abs(simd_normalize(strongest)) : SIMD3(repeating: 1 / 3.0.squareRoot())
        return GestureFeatures(peak: peak,
                               sharpness: peak / max(mean, 1e-6),
                               width: Double(energies.filter { $0 > peak * 0.35 }.count),
                               highFrequency: log((knock + 1e-8) / (movement + 1e-6)),
                               gyroPeak: core.map { simd_length($0.rotation) }.max() ?? 0,
                               axisX: axis.x, axisY: axis.y, axisZ: axis.z,
                               shape: template.map { similarity(window, to: $0) } ?? 0)
    }

    /// Peak-aligned waveform (3 axes x templateLength), unit length.
    static func waveform(_ window: [MotionSample], shift: Int = 0) -> [Double] {
        let start = peakIndex(window) - 3 + shift
        var values: [Double] = []
        for index in start..<(start + templateLength) {
            let h = window.indices.contains(index) ? window[index].highPass : .zero
            values += [h.x, h.y, h.z]
        }
        return normalized(values)
    }

    /// Best match against the template, allowing one sample of misalignment and either polarity.
    static func similarity(_ window: [MotionSample], to template: [Double]) -> Double {
        (-1...1).map { abs(dot(waveform(window, shift: $0), template)) }.max() ?? 0
    }

    /// Average of the training waveforms, each flipped to agree with the first.
    static func template(from windows: [[MotionSample]]) -> [Double]? {
        guard let first = windows.first.map({ waveform($0) }) else { return nil }
        var sum = [Double](repeating: 0, count: first.count)
        for window in windows {
            let shape = waveform(window)
            let sign: Double = dot(shape, first) < 0 ? -1 : 1
            for index in sum.indices { sum[index] += shape[index] * sign }
        }
        return normalized(sum)
    }

    private static func normalized(_ values: [Double]) -> [Double] {
        let norm = values.map { $0 * $0 }.reduce(0, +).squareRoot()
        return norm > 0 ? values.map { $0 / norm } : values
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map(*).reduce(0, +)
    }
}

struct GestureModel: Codable {
    struct Example: Codable {
        var label: GestureLabel
        var features: GestureFeatures
    }

    var triggerThreshold: Double
    var examples: [Example]
    var template: [Double]?

    static let untrained = GestureModel(triggerThreshold: 0.08, examples: [], template: nil)

    var isTrained: Bool { examples.contains { $0.label == .pinch } }

    static func train(pinches: [[MotionSample]], noise: [[MotionSample]]) -> GestureModel {
        let template = GestureAnalysis.template(from: pinches)
        let pinchFeatures = pinches.map { GestureAnalysis.features(of: $0, template: template) }
        // Trigger at half the strength of the weaker pinches so none are missed.
        let peaks = pinchFeatures.map(\.peak).sorted()
        let weak = peaks.isEmpty ? untrained.triggerThreshold : peaks[peaks.count * 15 / 100]
        let threshold = max(0.02, weak * 0.5)
        // Movement below the trigger never reaches the classifier, so it isn't worth keeping.
        let noiseFeatures = noise.map { GestureAnalysis.features(of: $0, template: template) }
            .filter { $0.peak >= threshold * 0.8 }
        return GestureModel(triggerThreshold: threshold,
                            examples: pinchFeatures.map { Example(label: .pinch, features: $0) }
                                + noiseFeatures.map { Example(label: .noise, features: $0) },
                            template: template)
    }
}

/// k-nearest-neighbour classifier. Anything far from every trained pinch is rejected outright.
struct PinchClassifier {
    let model: GestureModel
    private let mean: [Double]
    private let scale: [Double]
    private let points: [(label: GestureLabel, vector: [Double])]
    private let pinchRadius: Double

    init(model: GestureModel) {
        self.model = model
        let raw = model.examples.map { (label: $0.label, vector: $0.features.vector) }
        let dims = GestureFeatures.weights.count
        let count = Double(max(raw.count, 1))
        let mean = (0..<dims).map { d in raw.map { $0.vector[d] }.reduce(0, +) / count }
        let scale = (0..<dims).map { d -> Double in
            let variance = raw.map { pow($0.vector[d] - mean[d], 2) }.reduce(0, +) / count
            return GestureFeatures.weights[d] / max(variance.squareRoot(), 1e-3)
        }
        let points = raw.map { example in
            (label: example.label, vector: (0..<dims).map { d in (example.vector[d] - mean[d]) * scale[d] })
        }
        self.mean = mean
        self.scale = scale
        self.points = points

        // Typical spacing between this person's own pinches sets how far a new one may be.
        let pinches = points.filter { $0.label == .pinch }.map(\.vector)
        let spacing = pinches.indices.compactMap { i in
            pinches.indices.filter { $0 != i }.map { Self.distance(pinches[i], pinches[$0]) }.min()
        }.sorted()
        let typical = spacing.isEmpty ? 0 : spacing[min(spacing.count - 1, spacing.count * 9 / 10)]
        pinchRadius = max(typical * 1.75, 1.5)
    }

    func classify(_ features: GestureFeatures) -> GestureLabel {
        guard model.isTrained else { return Self.ruleOfThumb(features) }
        let query = features.vector.indices.map { (features.vector[$0] - mean[$0]) * scale[$0] }
        let ranked = points.map { (label: $0.label, distance: Self.distance(query, $0.vector)) }
            .sorted { $0.distance < $1.distance }
        guard let nearestPinch = ranked.first(where: { $0.label == .pinch }),
              nearestPinch.distance <= pinchRadius else { return .noise }

        var pinch = 0.0
        var noise = 0.0
        for neighbour in ranked.prefix(5) {
            let weight = 1 / (neighbour.distance + 0.1)
            if neighbour.label == .pinch { pinch += weight } else { noise += weight }
        }
        return pinch > noise * 1.2 ? .pinch : .noise
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }

    /// Used before training: a short, sharp knock with little arm rotation.
    private static func ruleOfThumb(_ f: GestureFeatures) -> GestureLabel {
        f.sharpness > 3.5 && f.width <= 3 && f.gyroPeak < 1.2 && f.highFrequency > 0 ? .pinch : .noise
    }
}

/// Finds sharp knocks in the 100 Hz motion stream and captures a short window around each one.
final class GestureDetector {
    static let preSamples = 5
    static let postSamples = 10

    var threshold: Double
    /// Called as soon as a knock starts, before it is classified.
    var onCandidate: () -> Void = {}
    /// Called with the captured window and the time the knock started.
    var onWindow: ([MotionSample], TimeInterval) -> Void = { _, _ in }

    private var history: [MotionSample] = []
    private var capture: [MotionSample]?
    private var captureStart: TimeInterval = 0
    private var remaining = 0
    private var previous: SIMD3<Double>?
    private var beforePrevious: SIMD3<Double>?
    private var noiseFloor = 0.0
    private var refractoryUntil: TimeInterval = 0
    private var lastTime: TimeInterval = 0

    init(threshold: Double) {
        self.threshold = threshold
    }

    func process(acceleration: SIMD3<Double>, rotation: SIMD3<Double>, time: TimeInterval) {
        lastTime = time
        var highPass = SIMD3<Double>.zero
        if let previous, let beforePrevious { highPass = acceleration - 2 * previous + beforePrevious }
        beforePrevious = previous
        previous = acceleration
        let sample = MotionSample(acceleration: acceleration, highPass: highPass, rotation: rotation,
                                  energy: simd_length(highPass))

        if capture != nil {
            capture!.append(sample)
            remaining -= 1
            if remaining == 0 {
                let window = capture!
                capture = nil
                refractoryUntil = time + 0.05
                onWindow(window, captureStart)
            }
            return
        }

        // A steady background buzz (walking, a vibrating table) raises the bar instead of triggering.
        noiseFloor += (sample.energy - noiseFloor) * 0.01
        if sample.energy > max(threshold, noiseFloor * 5) && time > refractoryUntil {
            capture = history + [sample]
            captureStart = time
            remaining = Self.postSamples
            onCandidate()
        }
        history.append(sample)
        if history.count > Self.preSamples { history.removeFirst() }
    }

    /// Ignore knocks for a while, e.g. the watch's own haptic tap.
    func mute(for duration: TimeInterval) {
        refractoryUntil = max(refractoryUntil, lastTime + duration)
    }
}
