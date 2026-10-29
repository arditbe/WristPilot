import Foundation

/// Turns the watch's pointing packets into cursor movement in points. No events, just math.
///
/// 1. Stillness lock. When the hand is still the cursor locks. The decision uses the pointing speed
///    after a 3 Hz low-pass, which removes hand tremor (8 to 12 Hz) but keeps deliberate movement.
///    Leaving the lock takes 40 ms to confirm, so a pinch (reported as `held`) can cancel it, and an
///    unlock followed by a pinch within 150 ms is undone.
/// 2. Dead reckoning. Bluetooth stalls for up to ~90 ms about once a second. The cursor keeps gliding
///    at the current speed and late data is blended in instead of arriving as a jump.
/// 3. Tremor filter. Two low-pass stages whose cutoff rises with speed: heavy smoothing while aiming,
///    almost none for quick moves. Total distance is preserved.
/// 4. Pointer acceleration. Low gain when slow for precision, high gain when fast.
struct PointerFilter {
    struct Tuning: Equatable {
        /// Points per radian when moving slowly.
        var precision = 700.0
        /// Points per radian when moving fast.
        var speed = 9000.0
        /// 0 to 1. How strongly tremor is filtered and how firmly the cursor locks.
        var steadiness = 0.5
        /// Milliseconds over which late data is blended in after a stall.
        var smoothing = 15.0
    }

    var tuning = Tuning()
    private(set) var isLocked = true

    private var window: [(delta: SIMD2<Double>, span: Double)] = []
    private var slowRate = SIMD2<Double>.zero
    private var slowRate2 = SIMD2<Double>.zero
    private var quietFor = 0.0
    private var unlockedAt: TimeInterval = -1
    private var unlockingSince: TimeInterval?
    private var sinceUnlock = SIMD2<Double>.zero
    private var received = SIMD2<Double>.zero
    private var predicted = SIMD2<Double>.zero
    private var applied = SIMD2<Double>.zero
    private var velocity = SIMD2<Double>.zero
    private var lastPacket: TimeInterval = 0
    private var stage1 = SIMD2<Double>.zero
    private var stage2 = SIMD2<Double>.zero

    /// Feeds one motion packet: pointing change (rad), the time it covers (s), and whether the
    /// watch was holding the cursor for a gesture.
    mutating func add(_ delta: SIMD2<Double>, span: Double, held: Bool, now: TimeInterval) {
        lastPacket = now
        let (accepted, acceptedSpan) = gate(delta, span: max(span, 0.004), held: held, now: now)
        received += accepted
        predicted = .zero
        velocity += (accepted / acceptedSpan - velocity) * min(1, acceptedSpan / 0.02)
    }

    /// Advances by `dt` seconds and returns how far to move the cursor, in points.
    mutating func step(now: TimeInterval, dt: Double) -> SIMD2<Double> {
        // Glide at full speed for 100 ms of silence, then ease off by 180 ms in case the watch is gone.
        let confidence = min(max(1 - (now - lastPacket - 0.1) / 0.08, 0), 1)
        let glide = velocity * confidence * dt
        predicted += glide
        var next = applied + glide
        let blend = tuning.smoothing <= 0 ? 1 : 1 - exp(-dt / (tuning.smoothing / 1000))
        next += (received + predicted - next) * blend
        let raw = (next - applied) / dt
        applied = next

        let cutoff = (6 - 4.5 * tuning.steadiness) + 8 * max(Self.length(raw), Self.length(stage2))
        let alpha = 1 - exp(-2 * Double.pi * 1.5 * cutoff * dt)
        stage1 += (raw - stage1) * alpha
        stage2 += (stage1 - stage2) * alpha

        let speed = Self.length(stage2)
        let ramp = speed * speed / (speed * speed + 0.7 * 0.7)
        let gain = tuning.precision + (max(tuning.speed, tuning.precision) - tuning.precision) * ramp
        return stage2 * dt * gain
    }

    /// Drops any movement in flight, e.g. on pause or disconnect.
    mutating func reset() {
        received = applied
        predicted = .zero
        velocity = .zero
        stage1 = .zero
        stage2 = .zero
        window.removeAll()
        slowRate = .zero
        slowRate2 = .zero
        isLocked = true
    }

    private mutating func gate(_ delta: SIMD2<Double>, span: Double, held: Bool, now: TimeInterval) -> (SIMD2<Double>, Double) {
        let steadiness = tuning.steadiness
        guard steadiness > 0 else {
            isLocked = false
            return (delta, span)
        }
        if held {
            // A pinch is starting. If the cursor only just unlocked, the pinch's own twitch did it.
            if !isLocked && now - unlockedAt < 0.15 {
                received -= sinceUnlock
                velocity = .zero
            }
            isLocked = true
            unlockingSince = nil
            window.removeAll()
            slowRate = .zero
            slowRate2 = .zero
            return (.zero, span)
        }

        let alpha = 1 - exp(-2 * Double.pi * 3 * span)
        slowRate += (delta / span - slowRate) * alpha
        slowRate2 += (slowRate - slowRate2) * alpha
        let intent = Self.length(slowRate2)
        window.append((delta, span))
        var total = window.reduce(0) { $0 + $1.span }
        while total > 0.15, window.count > 1 { total -= window.removeFirst().span }

        if isLocked {
            guard intent > 0.08 * steadiness else {
                unlockingSince = nil
                return (.zero, span)
            }
            let since = unlockingSince ?? now
            unlockingSince = since
            guard now - since >= 0.04 else { return (.zero, span) }
            // Deliver what was held back while confirming, at its real speed.
            let net = window.reduce(SIMD2<Double>.zero) { $0 + $1.delta }
            isLocked = false
            unlockingSince = nil
            unlockedAt = now
            quietFor = 0
            sinceUnlock = net
            window.removeAll()
            return (net, total)
        }
        if now - unlockedAt < 0.15 { sinceUnlock += delta }
        quietFor = intent < 0.04 * steadiness ? quietFor + span : 0
        if quietFor >= 0.15 {
            isLocked = true
            window.removeAll()
        }
        return (delta, span)
    }

    static func length(_ v: SIMD2<Double>) -> Double {
        (v.x * v.x + v.y * v.y).squareRoot()
    }
}
