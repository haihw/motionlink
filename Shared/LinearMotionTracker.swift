import Foundation
import simd

struct MotionEstimate: Sendable, Equatable {
    var acceleration = MotionVector.zero // m/s², in the neutral frame
    var velocity = MotionVector.zero // m/s, short-gesture estimate
    var isAvailable = false
    var isRotating = false
    static let unavailable = Self()
    var speed: Double { velocity.magnitude }
    var hasAcceleration: Bool { acceleration.magnitude >= LinearMotionTracker.noiseFloor }
    var isMoving: Bool { isAvailable && (speed >= 0.04 || hasAcceleration) }
    var state: String {
        guard isAvailable else { return "Unavailable" }
        if isMoving { return "Movement detected" }
        return isRotating ? "Rotating" : "Quiet sensors"
    }
    /// Prefer velocity during braking; acceleration can point against travel.
    var direction: SIMD3<Float> {
        guard isAvailable else { return .zero }
        let vector = speed >= 0.04 ? velocity.simdValue : (hasAcceleration ? acceleration.simdValue : .zero)
        return simd_length(vector) > 0 ? simd_normalize(vector) : .zero
    }
    var directionLabel: String {
        let vector = direction
        guard simd_length(vector) > 0 else { return isRotating ? "Rotation only" : "No recent movement" }
        let index = (0..<3).max { abs(vector[$0]) < abs(vector[$1]) } ?? 0
        return MotionDirection.allCases.first { $0.axis == index && $0.sign == (vector[index] >= 0 ? 1 : -1) }?.title ?? "—"
    }
    func strength(for direction: MotionDirection) -> Float {
        let component = self.direction[direction.axis] * direction.sign
        return max(0, component)
    }
}

enum MotionDirection: Int, CaseIterable, Identifiable, Sendable {
    case right, left, up, down, forward, backward
    var id: Int { rawValue }
    var axis: Int { rawValue / 2 }
    var sign: Float { rawValue.isMultiple(of: 2) ? 1 : -1 }
    var vector: SIMD3<Float> {
        var value = SIMD3<Float>.zero; value[axis] = sign; return value
    }
    var title: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        case .up: "Up"
        case .down: "Down"
        case .forward: "Toward you"
        case .backward: "Away"
        }
    }
    var axisLabel: String { "\(sign > 0 ? "+" : "−")\(["X", "Y", "Z"][axis])" }
}

extension MotionVector {
    var simdValue: SIMD3<Float> { SIMD3(Float(x), Float(y), Float(z)) }
    init(_ value: SIMD3<Float>) { self.init(x: Double(value.x), y: Double(value.y), z: Double(value.z)) }
}

/// A deliberately bounded inertial estimate for hand gestures, not a positional tracker.
/// Calibration assumes zero initial velocity. Damping and a quiet-sensor heuristic
/// control drift, but cannot distinguish stillness from constant-speed travel.
struct LinearMotionTracker: Sendable {
    static let standardGravity: Float = 9.80665
    static let noiseFloor: Double = 0.15
    private var lastTimestamp: Double?
    private var filteredAcceleration = SIMD3<Float>.zero
    private var previousAcceleration = SIMD3<Float>.zero
    private var velocity = SIMD3<Float>.zero
    private var quietDuration = 0.0

    mutating func reset() { self = Self() }

    mutating func update(_ sample: MotionSample, orientation: MotionQuaternion) -> MotionEstimate {
        guard sample.isValid, orientation.isValid else { reset(); return .unavailable }
        // Rotate device acceleration into a fixed neutral frame before integrating.
        let raw = orientation.rotation.act(sample.acceleration.simdValue * Self.standardGravity)
        guard let previousTime = lastTimestamp else {
            lastTimestamp = sample.timestamp
            filteredAcceleration = raw
            previousAcceleration = deadband(raw)
            return snapshot(rotationRate: sample.rotationRate)
        }
        let dt = sample.timestamp - previousTime
        guard dt > 0, dt <= 0.2 else {
            // Never integrate across paused streams, reordered clocks, or large gaps.
            reset()
            lastTimestamp = sample.timestamp
            filteredAcceleration = raw
            previousAcceleration = deadband(raw)
            return .unavailable
        }
        lastTimestamp = sample.timestamp
        let blend = Float(1 - exp(-dt / 0.045))
        filteredAcceleration += (raw - filteredAcceleration) * blend
        let acceleration = deadband(filteredAcceleration)
        velocity += (previousAcceleration + acceleration) * Float(0.5 * dt)
        velocity *= Float(exp(-dt / 3.0))
        previousAcceleration = acceleration

        if simd_length(raw) < Float(Self.noiseFloor), sample.rotationRate.magnitude < 0.12 {
            quietDuration += dt
            if quietDuration >= 0.65 { velocity = .zero }
        } else { quietDuration = 0 }
        return snapshot(rotationRate: sample.rotationRate)
    }

    private func deadband(_ value: SIMD3<Float>) -> SIMD3<Float> {
        simd_length(value) < Float(Self.noiseFloor) ? .zero : value
    }
    private func snapshot(rotationRate: MotionVector) -> MotionEstimate {
        MotionEstimate(acceleration: MotionVector(filteredAcceleration), velocity: MotionVector(velocity),
                       isAvailable: true, isRotating: rotationRate.magnitude >= 0.12)
    }
}
