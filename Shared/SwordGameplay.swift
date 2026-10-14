import Foundation
import simd

struct WatermelonTarget: Sendable, Identifiable {
    let id: Int
    let name: String
    let center: SIMD3<Float>
    let radius: Float
    static let orchard = [
        Self(id: 0, name: "Crimson", center: [-0.90, 0.30, -0.25], radius: 0.31),
        Self(id: 1, name: "Golden", center: [0, 0.65, -0.50], radius: 0.36),
        Self(id: 2, name: "Mini", center: [0.95, 0.20, -0.20], radius: 0.26)
    ]
    func position(at time: Double) -> SIMD3<Float> {
        center + SIMD3(Float(sin(time * 0.9 + Double(id) * 1.7)) * 0.045, 0, 0)
    }
}

struct SwordPose: Sendable {
    static let bladeStart: Float = 0.17
    static let bladeLength: Float = 1.50
    var grip: SIMD3<Float>
    var rotation: MotionQuaternion
    var base: SIMD3<Float> { grip + rotation.rotation.act(SIMD3(0, Self.bladeStart, 0)) }
    var tip: SIMD3<Float> { grip + rotation.rotation.act(SIMD3(0, Self.bladeLength, 0)) }
    var isValid: Bool { rotation.isValid && (0..<3).allSatisfy { grip[$0].isFinite && abs(grip[$0]) < 10 } }

    /// Translation is estimated in the fixed neutral frame; attitude retains all three axes.
    static func phone(orientation: MotionQuaternion, displacement: SIMD3<Float> = .zero) -> Self {
        Self(grip: SIMD3<Float>(0, -0.55, 0.65) + displacement, rotation: orientation)
    }
    static func autoplay(at time: Double) -> (pose: Self, hasSwingEnergy: Bool) {
        let safeTime = time.isFinite ? max(0, time) : 0
        let index = min(2, Int(min(7.2, safeTime) / 2.4))
        let target = WatermelonTarget.orchard[index]
        let phase = safeTime - Double(index) * 2.4
        let progress = Float(min(1, max(0, (phase - 0.65) / 0.4)))
        let center = target.position(at: safeTime)
        let rotations = [
            simd_quatf(angle: -0.35, axis: SIMD3<Float>(1, 0, 0)),
            simd_quatf(angle: 0.55, axis: SIMD3<Float>(0, 0, 1)) * simd_quatf(angle: -0.4, axis: SIMD3<Float>(1, 0, 0)),
            simd_quatf(angle: -0.6, axis: SIMD3<Float>(0, 0, 1)) * simd_quatf(angle: 0.35, axis: SIMD3<Float>(0, 1, 0))
        ]
        let rotation = rotations[index]
        let direction = rotation.act(SIMD3<Float>(1, 0, 0))
        let bladeAxis = rotation.act(SIMD3<Float>(0, 1, 0))
        return (Self(grip: center - bladeAxis * 0.8 + direction * (-0.65 + progress * 1.30), rotation: MotionQuaternion(rotation)),
                phase >= 0.65 && phase <= 1.1)
    }
    static func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float { min(upper, max(lower, value)) }
    static func interpolated(_ first: Self, _ second: Self, fraction: Float) -> Self {
        Self(grip: first.grip + (second.grip - first.grip) * fraction,
             rotation: MotionQuaternion(simd_slerp(first.rotation.rotation, second.rotation.rotation, fraction)))
    }
}

struct SwordSlice: Sendable {
    let targetID: Int
    let normal: SIMD3<Float>
    let offset: Float // Signed plane distance from the fruit center.
    let contact: SIMD3<Float>
    let direction: SIMD3<Float>
    var cutRotation: simd_quatf { simd_quatf(from: SIMD3<Float>(1, 0, 0), to: normal) }
}

struct SwordGameEngine: Sendable {
    private(set) var cutTargets: Set<Int> = []
    private var previousPose: SwordPose?
    var complete: Bool { cutTargets.count == WatermelonTarget.orchard.count }
    mutating func reset() { self = Self() }
    mutating func clearSweep() { previousPose = nil }

    /// Sweep the actual 3D blade, retaining its face normal and hit-plane offset.
    mutating func step(pose: SwordPose, deltaTime: Double, hasSwingEnergy: Bool, time: Double) -> [SwordSlice] {
        guard pose.isValid, time.isFinite else { clearSweep(); return [] }
        defer { previousPose = pose }
        guard let previousPose, deltaTime > 0, deltaTime <= 0.15 else { return [] }
        let gripTravel = simd_distance(previousPose.grip, pose.grip)
        let tipTravel = simd_distance(previousPose.tip, pose.tip)
        guard hasSwingEnergy, max(gripTravel, tipTravel) / Float(deltaTime) >= 0.65 else { return [] }
        let dot = min(1, abs(simd_dot(previousPose.rotation.rotation.vector, pose.rotation.rotation.vector)))
        let angularTravel = 2 * acos(dot) * SwordPose.bladeLength
        let steps = max(1, min(160, Int(ceil(max(max(gripTravel, tipTravel), angularTravel) / 0.025))))
        var hits: [SwordSlice] = []
        for target in WatermelonTarget.orchard where !cutTargets.contains(target.id) {
            let center = target.position(at: time)
            for step in 0...steps {
                let fraction = Float(step) / Float(steps)
                let swept = SwordPose.interpolated(previousPose, pose, fraction: fraction)
                let q = swept.rotation.rotation
                let localCenter = q.inverse.act(center - swept.grip)
                let y = min(SwordPose.bladeLength, max(SwordPose.bladeStart, localCenter.y))
                let width: Float = y <= 1.25 ? 0.065 - (y - 0.17) / 1.08 * 0.02 : max(0, (1.5 - y) / 0.25 * 0.045)
                let localContact = SIMD3<Float>(min(width, max(-width, localCenter.x)), y, 0)
                let closest = swept.grip + q.act(SIMD3(localContact.x, y, min(0.03, max(-0.03, localCenter.z))))
                guard simd_distance(center, closest) <= target.radius else { continue }

                // Estimate material-point velocity on either side of contact.
                let beforeFraction = max(0, fraction - 0.01), afterFraction = min(1, fraction + 0.01)
                let before = SwordPose.interpolated(previousPose, pose, fraction: beforeFraction)
                let after = SwordPose.interpolated(previousPose, pose, fraction: afterFraction)
                let displacement = after.grip + after.rotation.rotation.act(localContact)
                    - before.grip - before.rotation.rotation.act(localContact)
                let span = Float(deltaTime) * (afterFraction - beforeFraction)
                guard span > 0 else { continue }
                let velocity = displacement / span
                let speed = simd_length(velocity)
                let edge = q.act(SIMD3<Float>(1, 0, 0))
                // Flat-side pushes and straight thrusts aren't edge-first slashes.
                guard speed >= 0.65, abs(simd_dot(velocity, edge)) / speed >= 0.6 else { continue }
                let normal = q.act(SIMD3<Float>(0, 0, 1))
                let contact = swept.grip + q.act(localContact)
                let offset = simd_dot(contact - center, normal)
                guard abs(offset) < target.radius * 0.98 else { continue }
                cutTargets.insert(target.id)
                hits.append(SwordSlice(targetID: target.id, normal: normal, offset: offset,
                                       contact: contact, direction: velocity / speed))
                break
            }
        }
        return hits
    }

    static func distance(_ point: SIMD3<Float>, toSegmentFrom start: SIMD3<Float>, to end: SIMD3<Float>) -> Float {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0.000001 else { return simd_distance(point, start) }
        let fraction = min(1, max(0, simd_dot(point - start, segment) / lengthSquared))
        return simd_distance(point, start + segment * fraction)
    }
}

/// Integrates short-gesture velocity on the sensor clock, never the render clock.
/// Position holds when velocity reaches zero. Bounds limit accumulated inertial drift.
struct SwordTranslationTracker: Sendable {
    static let gain: Float = 3
    static let limits = SIMD3<Float>(1.35, 0.8, 1.1)
    private(set) var displacement = SIMD3<Float>.zero
    private var lastTimestamp: Double?
    private var previousVelocity = SIMD3<Float>.zero

    mutating func reset() { self = Self() }

    mutating func update(_ movement: MotionEstimate, timestamp: Double) -> SIMD3<Float> {
        guard timestamp.isFinite, movement.isAvailable, movement.velocity.isValid else {
            reset(); return displacement
        }
        let velocity = movement.speed >= 0.04 ? movement.velocity.simdValue : .zero
        guard let lastTimestamp else {
            self.lastTimestamp = timestamp; previousVelocity = velocity
            return displacement
        }
        let dt = timestamp - lastTimestamp
        guard dt > 0, dt <= 0.2 else {
            reset(); self.lastTimestamp = timestamp; previousVelocity = velocity
            return displacement
        }
        self.lastTimestamp = timestamp
        displacement += (previousVelocity + velocity) * Float(dt * 0.5) * Self.gain
        for axis in 0..<3 {
            displacement[axis] = min(Self.limits[axis], max(-Self.limits[axis], displacement[axis]))
        }
        previousVelocity = velocity
        return displacement
    }
}
