import Foundation
import simd
import Testing
@testable import MotionLinkCore

private func motion(time: Double, acceleration: SIMD3<Float> = .zero, gyro: SIMD3<Float> = .zero) -> MotionSample {
    MotionSample(sequence: 1, timestamp: time, attitude: .identity, rotationRate: MotionVector(gyro),
                 acceleration: MotionVector(acceleration / LinearMotionTracker.standardGravity), gravity: MotionVector(x: 0, y: -1, z: 0))
}

@Test("Acceleration is converted to m/s² and transformed into the neutral frame")
func neutralAcceleration() {
    var tracker = LinearMotionTracker()
    let quarterTurn = MotionQuaternion(simd_quatf(angle: .pi / 2, axis: [0, 0, 1]))
    let estimate = tracker.update(motion(time: 0, acceleration: [2, 0, 0]), orientation: quarterTurn)
    #expect(abs(estimate.acceleration.x) < 0.00001)
    #expect(abs(estimate.acceleration.y - 2) < 0.00001)
    #expect(estimate.directionLabel == "Up")
}

@Test("Speed uses sensor time and remains consistent across sampling rates", arguments: [30, 60, 120])
func sampleRateIndependentSpeed(rate: Int) {
    var tracker = LinearMotionTracker()
    var estimate = MotionEstimate.unavailable
    for tick in 0...rate {
        estimate = tracker.update(motion(time: Double(tick) / Double(rate), acceleration: [1, 0, 0]), orientation: .identity)
    }
    let dampedIntegral = 3 * (1 - exp(-1.0 / 3))
    #expect(abs(estimate.speed - dampedIntegral) < 0.02)
    #expect(estimate.directionLabel == "Right")
}

@Test("Rotating a device cannot rotate the accumulated velocity frame")
func stableVelocityFrame() {
    var tracker = LinearMotionTracker()
    var estimate = MotionEstimate.unavailable
    for tick in 0...60 {
        let angle = Float(tick) / 60 * .pi
        let q = simd_quatf(angle: angle, axis: [0, 0, 1])
        let deviceAcceleration = q.inverse.act(SIMD3<Float>(1, 0, 0))
        estimate = tracker.update(motion(time: Double(tick) / 60, acceleration: deviceAcceleration), orientation: MotionQuaternion(q))
    }
    #expect(estimate.velocity.x > 0.8)
    #expect(abs(estimate.velocity.y) < 0.00001)
    #expect(estimate.directionLabel == "Right")
}

@Test("Braking acceleration can point opposite to estimated travel")
func brakingDirection() {
    var tracker = LinearMotionTracker()
    for tick in 0...60 { _ = tracker.update(motion(time: Double(tick) / 60, acceleration: [1, 0, 0]), orientation: .identity) }
    var estimate = MotionEstimate.unavailable
    for tick in 61...70 { estimate = tracker.update(motion(time: Double(tick) / 60, acceleration: [-1, 0, 0]), orientation: .identity) }
    #expect(estimate.acceleration.x < -0.8)
    #expect(estimate.velocity.x > 0.5)
    #expect(estimate.directionLabel == "Right")
    #expect(estimate.strength(for: .right) > 0.9999)
    #expect(estimate.strength(for: .left) == 0)
}

@Test("Quiet sensor noise and pure rotation do not invent linear motion")
func quietAndRotation() {
    var tracker = LinearMotionTracker()
    var estimate = MotionEstimate.unavailable
    for tick in 0...120 {
        estimate = tracker.update(motion(time: Double(tick) / 60, acceleration: [0.01, -0.01, 0.01]), orientation: .identity)
    }
    #expect(estimate.speed == 0)
    #expect(!estimate.isMoving)
    estimate = tracker.update(motion(time: 121.0 / 60, gyro: [0, 2, 0]), orientation: .identity)
    #expect(estimate.isRotating)
    #expect(estimate.direction == .zero)
    #expect(estimate.state == "Rotating")
}

@Test("Quiet intervals reset drift; explicit resets and stream gaps discard old velocity")
func lifecycleResets() {
    var tracker = LinearMotionTracker()
    for tick in 0...30 { _ = tracker.update(motion(time: Double(tick) / 60, acceleration: [1, 0, 0]), orientation: .identity) }
    var estimate = MotionEstimate.unavailable
    for tick in 31...90 { estimate = tracker.update(motion(time: Double(tick) / 60), orientation: .identity) }
    #expect(estimate.speed == 0)
    tracker.reset()
    estimate = tracker.update(motion(time: 2), orientation: .identity)
    #expect(estimate.speed == 0)
    _ = tracker.update(motion(time: 2.1, acceleration: [2, 0, 0]), orientation: .identity)
    estimate = tracker.update(motion(time: 3, acceleration: [2, 0, 0]), orientation: .identity)
    #expect(!estimate.isAvailable)
    #expect(estimate.speed == 0)
    estimate = tracker.update(motion(time: 2.9, acceleration: [2, 0, 0]), orientation: .identity)
    #expect(!estimate.isAvailable)
    #expect(estimate.speed == 0)
}

@Test("Diagonal travel highlights every participating signed axis")
func diagonalDirections() {
    let estimate = MotionEstimate(acceleration: .zero, velocity: MotionVector(x: 1, y: -1, z: 0), isAvailable: true)
    #expect(estimate.strength(for: .right) > 0.7)
    #expect(estimate.strength(for: .down) > 0.7)
    #expect(estimate.strength(for: .up) == 0)
    #expect(estimate.strength(for: .backward) == 0)
}
