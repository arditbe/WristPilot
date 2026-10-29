import CoreMotion
import Foundation
import simd
import WatchKit

/// Turns the 100 Hz motion stream into cursor movement, pinches and pinch scrolling.
final class MotionEngine: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var isScrolling = false
    @Published private(set) var lastGesture: String?
    @Published private(set) var isTrained = false
    /// Whether the extended runtime session keeps the app alive when the screen dims.
    @Published private(set) var isBackgroundActive = false

    let link: BLEClient

    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "wristpilot.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private let detector: GestureDetector
    private var classifier: PinchClassifier
    private var session: WKExtendedRuntimeSession?

    // Everything below is only touched on the motion queue.
    private var config = WatchConfig()
    private var paused = false
    private var trainingSink: (([MotionSample], TimeInterval) -> Void)?
    private var pointer = PointerMath()
    private var lastTimestamp: TimeInterval = 0
    private var previousSample: TimeInterval?
    private var aimSpeed = 0.0
    private var aimSpeedAtCandidate = 0.0
    /// Movement held back while a knock is being classified.
    private var holding = false
    private var held = SIMD2<Double>.zero
    /// Held movement that turned out to be real. Fed back in gradually.
    private var release = SIMD2<Double>.zero
    /// Keeps the cursor still after a gesture while the fingers let go.
    private var quietUntil: TimeInterval = 0
    private var phase = PinchPhase.idle

    private enum PinchPhase {
        case idle
        /// A pinch happened. Waiting to see if a second pinch or a tilt follows.
        case deciding(onset: TimeInterval, motion: SIMD2<Double>)
        case scrolling(stillSince: TimeInterval?)
    }

    private var samplesThisSecond = 0
    private var lagThisSecond = 0.0
    private var lagMaxThisSecond = 0.0
    private var secondStarted: TimeInterval = 0
    private var backgroundActive = false

    // Bump when the gesture features change, since older training no longer applies.
    private static let modelKey = "gestureModel.v3"
    /// Tilt after a pinch that starts scrolling (about 1.7 degrees).
    private static let scrollStartAngle = 0.03
    /// Movement after a pinch that means "click, then keep moving" (about 2.6 degrees).
    private static let moveOnAngle = 0.045

    init(link: BLEClient) {
        self.link = link
        var model = GestureModel.untrained
        if let data = UserDefaults.standard.data(forKey: Self.modelKey),
           let saved = try? JSONDecoder().decode(GestureModel.self, from: data) {
            model = saved
        }
        classifier = PinchClassifier(model: model)
        detector = GestureDetector(threshold: model.triggerThreshold)
        super.init()
        isTrained = model.isTrained
        detector.onCandidate = { [weak self] in self?.candidateStarted() }
        detector.onWindow = { [weak self] in self?.handleWindow($0, onset: $1) }
        link.onConfig = { [weak self] config in self?.queue.addOperation { self?.config = config } }
    }

    func start() {
        startSession()
        guard !motion.isDeviceMotionActive, motion.isDeviceMotionAvailable else { return }
        let device = WKInterfaceDevice.current()
        let towardHand = (device.wristLocation == .left) == (device.crownOrientation == .right)
        queue.addOperation { self.pointer = PointerMath(towardHand: towardHand) }
        motion.deviceMotionUpdateInterval = 1.0 / 100
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            if let data { self?.handle(data) }
        }
        isRunning = true
    }

    func togglePause() {
        let newValue = !isPaused
        isPaused = newValue
        queue.addOperation {
            self.paused = newValue
            self.resetGestures()
        }
        link.setPaused(newValue)
        playHaptic(newValue ? .stop : .start)
    }

    /// Plays a haptic without letting its vibration register as a pinch.
    func playHaptic(_ type: WKHapticType) {
        queue.addOperation { self.detector.mute(for: 0.25) }
        WKInterfaceDevice.current().play(type)
    }

    // MARK: Training

    func beginTraining(_ sink: @escaping ([MotionSample], TimeInterval) -> Void) {
        queue.addOperation {
            self.trainingSink = sink
            self.resetGestures()
            self.detector.threshold = 0.02
        }
    }

    func endTraining(saving newModel: GestureModel?) {
        queue.addOperation {
            self.trainingSink = nil
            if let newModel { self.classifier = PinchClassifier(model: newModel) }
            self.detector.threshold = self.classifier.model.triggerThreshold
        }
        guard let newModel else { return }
        isTrained = newModel.isTrained
        if let data = try? JSONEncoder().encode(newModel) {
            UserDefaults.standard.set(data, forKey: Self.modelKey)
        }
    }

    func resetTraining() {
        endTraining(saving: .untrained)
        UserDefaults.standard.removeObject(forKey: Self.modelKey)
    }

    // MARK: Motion queue

    private func handle(_ data: CMDeviceMotion) {
        let now = data.timestamp
        lastTimestamp = now
        recordDiagnostics(sampleTime: now)

        let dt = min(max(now - (previousSample ?? now - 0.01), 0.001), 0.05)
        previousSample = now
        let acceleration = SIMD3(data.userAcceleration.x, data.userAcceleration.y, data.userAcceleration.z)
        let rotation = SIMD3(data.rotationRate.x, data.rotationRate.y, data.rotationRate.z)
        let rate = pointer.rate(rotation: rotation, gravity: SIMD3(data.gravity.x, data.gravity.y, data.gravity.z))
        aimSpeed += (simd_length(rate) - aimSpeed) * min(1, dt / 0.1)

        detector.process(acceleration: acceleration, rotation: rotation, time: now)
        guard !paused else { return }
        if trainingSink != nil {
            link.addMotion(.zero, duration: dt, held: true)
            return
        }
        advance(delta: rate * dt, rate: rate, dt: dt, now: now)
    }

    private var decisionWindow: TimeInterval {
        config.doublePinch ? 0.42 : (config.pinchScroll ? 0.3 : 0)
    }

    private func advance(delta: SIMD2<Double>, rate: SIMD2<Double>, dt: TimeInterval, now: TimeInterval) {
        switch phase {
        case .idle:
            if holding {
                held += delta
                link.addMotion(.zero, duration: dt, held: true)
            } else if now < quietUntil {
                link.addMotion(.zero, duration: dt, held: true)
            } else {
                let fed = release * 0.2
                release -= fed
                link.addMotion(delta + fed, duration: dt, held: false)
            }

        case let .deciding(onset, motion):
            link.addMotion(.zero, duration: dt, held: true)
            // A second knock moves the arm by itself, so wait for its verdict before reading intent.
            if holding {
                held += delta
                return
            }
            let total = motion + delta
            phase = .deciding(onset: onset, motion: total)
            if config.pinchScroll && abs(total.y) > Self.scrollStartAngle && abs(total.y) > abs(total.x) * 1.3 {
                beginScrolling(with: total.y)
            } else if simd_length(total) > Self.moveOnAngle {
                // Clicked and kept moving: click where the pinch happened and give the movement back.
                phase = .idle
                fire(.pinch, onset: onset, settle: false)
                release += total
            } else if now - onset > decisionWindow {
                phase = .idle
                fire(.pinch, onset: onset)
            }

        case let .scrolling(stillSince):
            link.addMotion(.zero, duration: dt, held: true)
            if holding { return }
            link.addScroll(SIMD2(0, delta.y))
            let still = abs(rate.y) < 0.1 ? (stillSince ?? now) : nil
            if let still, now - still > 0.45 {
                endScrolling(now: now)
            } else {
                phase = .scrolling(stillSince: still)
            }
        }
    }

    private func candidateStarted() {
        aimSpeedAtCandidate = aimSpeed
        guard trainingSink == nil else { return }
        // Freezing in the middle of a fast sweep would feel like lag, and the Mac still
        // clicks where the pinch started, so only hold while aiming.
        if case .idle = phase, aimSpeed > 0.6 { return }
        holding = true
    }

    private func handleWindow(_ window: [MotionSample], onset: TimeInterval) {
        let wasHolding = holding
        let heldMotion = held
        holding = false
        held = .zero
        if let trainingSink {
            trainingSink(window, onset)
            return
        }
        guard !paused else { return }

        let features = GestureAnalysis.features(of: window, template: classifier.model.template)
        let isPinch = aimSpeedAtCandidate < 3 && classifier.classify(features) == .pinch

        switch phase {
        case .idle:
            if isPinch {
                if decisionWindow > 0 {
                    phase = .deciding(onset: onset, motion: .zero)
                } else {
                    fire(.pinch, onset: onset)
                }
            } else if wasHolding {
                release += heldMotion
            }

        case let .deciding(firstOnset, motion):
            if !isPinch {
                phase = .deciding(onset: firstOnset, motion: motion + heldMotion)
            } else if config.doublePinch {
                phase = .idle
                fire(.doublePinch, onset: firstOnset)
            } else {
                // Double pinch is turned off, so that was a click and this pinch starts over.
                fire(.pinch, onset: firstOnset, settle: false)
                phase = .deciding(onset: onset, motion: .zero)
            }

        case .scrolling:
            if isPinch { endScrolling(now: lastTimestamp) }
        }
    }

    private func fire(_ gesture: HandGesture, onset: TimeInterval, settle: Bool = true) {
        let age = UInt16(min(max(lastTimestamp - onset, 0) * 1000, 2000))
        link.send(.gesture(gesture, age: age))
        if settle { quietUntil = max(quietUntil, lastTimestamp + (config.haptics ? 0.25 : 0.15)) }
        if config.haptics {
            detector.mute(for: 0.3)
            DispatchQueue.main.async { WKInterfaceDevice.current().play(.click) }
        }
        DispatchQueue.main.async { self.lastGesture = gesture.title }
    }

    private func beginScrolling(with initial: Double) {
        phase = .scrolling(stillSince: nil)
        link.addScroll(SIMD2(0, initial))
        DispatchQueue.main.async {
            self.isScrolling = true
            self.lastGesture = "Scroll"
        }
    }

    private func endScrolling(now: TimeInterval) {
        phase = .idle
        quietUntil = max(quietUntil, now + 0.2)
        DispatchQueue.main.async { self.isScrolling = false }
    }

    private func resetGestures() {
        phase = .idle
        holding = false
        held = .zero
        release = .zero
        DispatchQueue.main.async { self.isScrolling = false }
    }

    private func recordDiagnostics(sampleTime: TimeInterval) {
        // Both clocks count from boot, so the difference is how late CoreMotion delivered the sample.
        let now = ProcessInfo.processInfo.systemUptime
        let lag = now - sampleTime
        samplesThisSecond += 1
        lagThisSecond += lag
        lagMaxThisSecond = max(lagMaxThisSecond, lag)
        guard now - secondStarted >= 1 else { return }
        link.updateDiagnostics(sampleRate: samplesThisSecond, motionLag: lagThisSecond / Double(samplesThisSecond),
                               motionLagMax: lagMaxThisSecond, background: backgroundActive)
        samplesThisSecond = 0
        lagThisSecond = 0
        lagMaxThisSecond = 0
        secondStarted = now
    }

    // MARK: Background runtime

    /// Keeps motion and Bluetooth running while the wrist is down and the screen dims.
    private func startSession() {
        if let session, session.state == .running || session.state == .scheduled { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
    }
}

extension MotionEngine: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { self.isBackgroundActive = true }
        queue.addOperation { self.backgroundActive = true }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        DispatchQueue.main.async {
            guard self.session === extendedRuntimeSession else { return }
            self.session = nil
            self.isBackgroundActive = false
            self.queue.addOperation { self.backgroundActive = false }
        }
    }
}
