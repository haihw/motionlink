import simd
import Testing
@testable import MotionLinkCore

private func blade(x: Float, y: Float = -0.7, z: Float = -0.25, angle: Float = 0) -> SwordPose {
    SwordPose(grip: [x, y, z], rotation: MotionQuaternion(simd_quatf(angle: angle, axis: [0, 0, 1])))
}

@Test("A quick swept blade hits a melon between frame endpoints")
func fastSwordSweep() {
    var game = SwordGameEngine()
    #expect(game.step(pose: blade(x: -1.65), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0).isEmpty)
    let hits = game.step(pose: blade(x: -0.5), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0)
    #expect(hits.map(\.targetID) == [0])
    #expect(game.cutTargets == [0])
}

@Test("Idle contact and slow aiming cannot slash a watermelon")
func idleSwordContact() {
    var game = SwordGameEngine()
    _ = game.step(pose: blade(x: 0), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0)
    #expect(game.step(pose: blade(x: 0), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0).isEmpty)
    #expect(game.step(pose: blade(x: 0.001), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0).isEmpty)
    #expect(game.step(pose: blade(x: 0.5), deltaTime: 1.0 / 60, hasSwingEnergy: false, time: 0).isEmpty)
    #expect(game.cutTargets.isEmpty)
}

@Test("Blade depth and misses do not score")
func misses() {
    var game = SwordGameEngine()
    _ = game.step(pose: blade(x: -1.5, z: 1.5), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0)
    #expect(game.step(pose: blade(x: 1.5, z: 1.5), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0).isEmpty)
    game.reset()
    _ = game.step(pose: blade(x: -1.5, y: -3), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0)
    #expect(game.step(pose: blade(x: 1.5, y: -3), deltaTime: 1.0 / 60, hasSwingEnergy: true, time: 0).isEmpty)
}

@Test("Each fruit scores once and resetting restores all three")
func roundLifecycle() {
    var game = SwordGameEngine()
    _ = game.step(pose: blade(x: -1.7), deltaTime: 0.05, hasSwingEnergy: true, time: 0)
    #expect(Set(game.step(pose: blade(x: 1.7), deltaTime: 0.05, hasSwingEnergy: true, time: 0).map(\.targetID)) == [0, 1, 2])
    #expect(game.complete)
    #expect(game.step(pose: blade(x: -1.7), deltaTime: 0.05, hasSwingEnergy: true, time: 0).isEmpty)
    game.reset()
    #expect(game.cutTargets.isEmpty)
    #expect(!game.complete)
}

@Test("Re-centering and reconnecting do not create a teleport slash")
func recenterDoesNotSlash() {
    var game = SwordGameEngine()
    _ = game.step(pose: blade(x: -1.7), deltaTime: 0.016, hasSwingEnergy: true, time: 0)
    game.clearSweep()
    #expect(game.step(pose: blade(x: 1.7), deltaTime: 0.016, hasSwingEnergy: true, time: 0).isEmpty)
    #expect(game.cutTargets.isEmpty)
}

@Test("A long render gap cannot slash through skipped time")
func frameGapDoesNotSlash() {
    var game = SwordGameEngine()
    _ = game.step(pose: blade(x: -1.7), deltaTime: 0.016, hasSwingEnergy: true, time: 0)
    #expect(game.step(pose: blade(x: 1.7), deltaTime: 1, hasSwingEnergy: true, time: 1).isEmpty)
    #expect(game.cutTargets.isEmpty)
}

@Test("Forward tilt points forward and all attitude axes rotate the sword")
func phoneControls() {
    let forward = SwordPose.phone(orientation: MotionQuaternion(simd_quatf(angle: -.pi / 4, axis: [1, 0, 0])))
    let backward = SwordPose.phone(orientation: MotionQuaternion(simd_quatf(angle: .pi / 4, axis: [1, 0, 0])))
    #expect(forward.tip.z < forward.grip.z - 1)
    #expect(backward.tip.z > backward.grip.z + 1)
    #expect(forward.grip == backward.grip)
    let q = simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 1, 0))
        * simd_quatf(angle: -0.8, axis: SIMD3<Float>(1, 0, 0))
        * simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 0, 1))
    let pose = SwordPose.phone(orientation: MotionQuaternion(q))
    #expect(abs(simd_dot(pose.rotation.rotation.vector, q.vector)) > 0.99999)
    #expect(simd_distance(pose.tip - pose.grip, q.act([0, 1.5, 0])) < 0.00001)
    #expect(pose.grip == forward.grip)
}

@Test("The cut records the actual 3D blade plane, offset, and edge direction")
func angledCutPlane() throws {
    let q = simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 0, 1))
        * simd_quatf(angle: -0.65, axis: SIMD3<Float>(1, 0, 0))
        * simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0))
    let center = WatermelonTarget.orchard[1].position(at: 0)
    let edge = q.act(SIMD3<Float>(1, 0, 0)), normal = q.act(SIMD3<Float>(0, 0, 1))
    let grip = center - q.act(SIMD3<Float>(0, 0.8, 0)) + normal * 0.08
    var game = SwordGameEngine()
    _ = game.step(pose: SwordPose(grip: grip - edge * 0.6, rotation: MotionQuaternion(q)), deltaTime: 0.05, hasSwingEnergy: true, time: 0)
    let hits = game.step(pose: SwordPose(grip: grip + edge * 0.6, rotation: MotionQuaternion(q)), deltaTime: 0.05, hasSwingEnergy: true, time: 0)
    let hit = try #require(hits.first { $0.targetID == 1 })
    #expect(simd_distance(hit.normal, normal) < 0.00001)
    #expect(abs(hit.offset - 0.08) < 0.00001)
    #expect(simd_distance(hit.direction, edge) < 0.0001)
    #expect(abs(simd_dot(hit.contact - center, hit.normal) - hit.offset) < 0.00001)
    #expect(simd_distance(hit.cutRotation.act([1, 0, 0]), normal) < 0.00001)
}

@Test("Flat-side pushes and straight thrusts do not count as slashes")
func wrongBladeDirection() {
    let center = WatermelonTarget.orchard[1].position(at: 0)
    for direction in [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 1, 0)] {
        var game = SwordGameEngine()
        let grip = center - SIMD3<Float>(0, 0.8, 0)
        _ = game.step(pose: SwordPose(grip: grip - direction * 0.6, rotation: .identity), deltaTime: 0.05, hasSwingEnergy: true, time: 0)
        #expect(game.step(pose: SwordPose(grip: grip + direction * 0.6, rotation: .identity), deltaTime: 0.05, hasSwingEnergy: true, time: 0).isEmpty)
    }
}

@Test("A real wrist rotation can slice in depth without moving the grip")
func anchoredWristSweep() {
    var game = SwordGameEngine()
    let pitch = simd_quatf(angle: -0.8, axis: SIMD3<Float>(1, 0, 0))
    let first = SwordPose.phone(orientation: MotionQuaternion(simd_quatf(angle: -0.7, axis: SIMD3<Float>(0, 0, 1)) * pitch))
    let last = SwordPose.phone(orientation: MotionQuaternion(simd_quatf(angle: 0.7, axis: SIMD3<Float>(0, 0, 1)) * pitch))
    _ = game.step(pose: first, deltaTime: 0.05, hasSwingEnergy: true, time: 0)
    #expect(game.step(pose: last, deltaTime: 0.05, hasSwingEnergy: true, time: 0).contains { $0.targetID == 1 })
}

@Test("Angular sweeps detect fruit between rotated blade poses")
func rotationalSweep() {
    var game = SwordGameEngine()
    _ = game.step(pose: blade(x: 0, y: -0.6, angle: -0.9), deltaTime: 0.016, hasSwingEnergy: true, time: 0)
    let hits = game.step(pose: blade(x: 0, y: -0.6, angle: 0.9), deltaTime: 0.016, hasSwingEnergy: true, time: 0)
    #expect(hits.contains { $0.targetID == 1 })
}

@Test("The watch-demo trajectory slices all three actual targets")
func watchDemoCompletes() {
    var game = SwordGameEngine()
    for tick in 0...450 {
        let time = Double(tick) / 60
        let preview = SwordPose.autoplay(at: time)
        _ = game.step(pose: preview.pose, deltaTime: 1.0 / 60, hasSwingEnergy: preview.hasSwingEnergy, time: time)
    }
    #expect(game.complete)
    #expect(game.cutTargets == [0, 1, 2])
}
