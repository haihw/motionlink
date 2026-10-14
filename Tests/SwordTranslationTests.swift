import simd
import Testing
@testable import MotionLinkCore

private func travel(_ velocity: SIMD3<Float>) -> MotionEstimate {
    MotionEstimate(velocity: MotionVector(velocity), isAvailable: true)
}

@Test("Hand translation moves the sword along all six neutral-frame directions")
func translatedSwordAxes() {
    for axis in 0..<3 {
        for sign: Float in [-1, 1] {
            var tracker = SwordTranslationTracker()
            var velocity = SIMD3<Float>.zero; velocity[axis] = sign * 0.3
            for tick in 0...30 { _ = tracker.update(travel(velocity), timestamp: Double(tick) / 60) }
            #expect(abs(tracker.displacement[axis] - sign * 0.45) < 0.0001)
            let orientation = MotionQuaternion(simd_quatf(angle: 0.9, axis: [0, 1, 0]))
            let pose = SwordPose.phone(orientation: orientation, displacement: tracker.displacement)
            #expect(simd_distance(pose.grip - SwordPose.phone(orientation: .identity).grip, tracker.displacement) < 0.0001)
            #expect(pose.rotation == orientation)
        }
    }
}

@Test("Translation uses sensor time consistently at different sample rates", arguments: [30, 60, 120])
func translationSampleRates(rate: Int) {
    var tracker = SwordTranslationTracker()
    for tick in 0...rate { _ = tracker.update(travel([0.2, 0.1, -0.15]), timestamp: Double(tick) / Double(rate)) }
    #expect(simd_distance(tracker.displacement, [0.6, 0.3, -0.45]) < 0.0001)
}

@Test("A stopped hand holds its translated position and braking follows velocity")
func translationHold() {
    var tracker = SwordTranslationTracker()
    for tick in 0...30 { _ = tracker.update(travel([0.3, 0, 0]), timestamp: Double(tick) / 60) }
    let before = tracker.displacement.x
    var braking = travel([0.15, 0, 0]); braking.acceleration = MotionVector(x: -2, y: 0, z: 0)
    _ = tracker.update(braking, timestamp: 31.0 / 60)
    #expect(tracker.displacement.x > before)
    _ = tracker.update(travel(.zero), timestamp: 32.0 / 60)
    let stopped = tracker.displacement
    for tick in 33...120 { _ = tracker.update(travel(.zero), timestamp: Double(tick) / 60) }
    #expect(tracker.displacement == stopped)
}

@Test("Translation is bounded, reverses from a boundary, and resets on stream gaps")
func translationLimitsAndReset() {
    var tracker = SwordTranslationTracker()
    for tick in 0...60 { _ = tracker.update(travel([5, -5, 5]), timestamp: Double(tick) / 60) }
    #expect(tracker.displacement == SIMD3<Float>(1.35, -0.8, 1.1))
    for tick in 61...70 { _ = tracker.update(travel([-1, 1, -1]), timestamp: Double(tick) / 60) }
    #expect(tracker.displacement.x < 1.35 && tracker.displacement.y > -0.8 && tracker.displacement.z < 1.1)
    #expect(tracker.update(travel([1, 0, 0]), timestamp: 5) == .zero)
    _ = tracker.update(travel([1, 0, 0]), timestamp: 5.1)
    tracker.reset()
    #expect(tracker.displacement == .zero)
    #expect(tracker.update(.unavailable, timestamp: 5.2) == .zero)
}
