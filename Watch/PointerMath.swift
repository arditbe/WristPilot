import simd

/// Maps watch rotation to cursor movement by following where the forearm points.
///
/// The watch's x axis runs along the forearm, so only rotation that swings that axis moves the
/// cursor. Twisting the wrist spins around the forearm and is ignored at any arm angle.
struct PointerMath {
    /// Forearm direction toward the hand, in watch coordinates.
    var forearm = SIMD3<Double>(1, 0, 0)
    /// Reused when the arm points almost straight up or down and "right" is undefined.
    private var lastRight = SIMD3<Double>(0, -1, 0)

    init(towardHand: Bool = true) {
        forearm = SIMD3(towardHand ? 1 : -1, 0, 0)
    }

    /// Pointing rate in rad/s, x to the right and y down the screen.
    /// `rotation` and `gravity` are in watch coordinates; gravity points at the ground.
    mutating func rate(rotation: SIMD3<Double>, gravity: SIMD3<Double>) -> SIMD2<Double> {
        guard simd_length(gravity) > 0.1 else { return .zero }
        let up = -simd_normalize(gravity)
        let side = simd_cross(forearm, up)
        if simd_length(side) > 0.15 { lastRight = simd_normalize(side) }
        let right = lastRight
        let upward = simd_cross(right, forearm)
        return SIMD2(-simd_dot(rotation, upward), -simd_dot(rotation, right))
    }
}
