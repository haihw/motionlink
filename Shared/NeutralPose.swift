import Foundation

struct NeutralPoseCheck: Sendable, Equatable {
    var isUpright = false
    var isStill = false
    var stableDuration = 0.0
    var isReady: Bool { isUpright && isStill && stableDuration >= 0.6 }
}

/// Gravity verifies top-edge-up portrait posture. Facing the screen toward the
/// user cannot be inferred from gravity; the user confirms that explicitly.
struct NeutralPoseMonitor: Sendable {
    private var lastTimestamp: Double?
    private var steadyDuration = 0.0
    mutating func reset() { self = Self() }
    mutating func update(_ sample: MotionSample) -> NeutralPoseCheck {
        guard sample.isValid else { reset(); return .init() }
        let gravity = sample.gravity.magnitude
        let upright = (0.8...1.2).contains(gravity) && -sample.gravity.y / gravity >= cos(25 * .pi / 180)
        let still = sample.rotationRate.magnitude < 0.16
            && sample.acceleration.magnitude * Double(LinearMotionTracker.standardGravity) < 0.22
        let dt = lastTimestamp.map { sample.timestamp - $0 } ?? 0
        lastTimestamp = sample.timestamp
        if upright && still && dt > 0 && dt <= 0.2 { steadyDuration += dt }
        else { steadyDuration = 0 }
        return NeutralPoseCheck(isUpright: upright, isStill: still, stableDuration: min(0.6, steadyDuration))
    }
}
