import simd
import Testing
@testable import MotionLinkCore

private func cookUntil(_ engine: inout WokGameEngine, _ condition: (WokGameEngine) -> Bool) {
    for index in 0..<3600 {
        if condition(engine) { return }
        engine.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(index)))
    }
}

@Test("Starting cracks and drops a fresh egg before searing begins")
func freshWokEgg() {
    var game = WokGameEngine()
    #expect(game.phase == .ready)
    game.start(target: .soft)
    #expect(game.phase == .cracking && game.sear == [0, 0])
    game.step(deltaTime: 0.05, input: WokInput())
    #expect(game.eggPosition.y > 1)
    cookUntil(&game) { $0.phase == .cooking }
    #expect(game.eggPosition.y < 0.1)
    #expect(game.target == .soft)
}

@Test("Tilt slides the egg in the wok while the entire pan follows the phone")
func wokTiltSlides() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    let q = MotionQuaternion(simd_quatf(angle: -0.3, axis: [0, 0, 1]))
    let position = SIMD3<Float>(0.1, 0, -0.1)
    for tick in 0..<180 {
        let blend = min(1, Float(tick + 1) / 30)
        let rotation = MotionQuaternion(simd_slerp(MotionQuaternion.identity.rotation, q.rotation, blend))
        game.step(deltaTime: 1.0 / 60, input: WokInput(rotation: rotation, translation: position * blend, sampleID: UInt64(tick)))
    }
    let local = q.rotation.inverse.act(game.eggPosition - position)
    #expect(local.x > 0.2)
    #expect(game.panPosition == position && game.panRotation == q)
    #expect(game.phase == .cooking)
}

@Test("A stationary egg sears but cannot flip without an upward gesture")
func wokNoPhantomFlip() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.sear[0] > 0.6 }
    #expect(game.flipWindow)
    #expect(game.flips == 0 && game.attempts == 0 && game.sear[1] == 0)
}

@Test("A flick works before ideal cooking timing but receives no perfect-flip bonus")
func wokEarlyToss() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    game.step(deltaTime: 1.0 / 60, input: WokInput(acceleration: [0, 7, -4], gyro: [1, 0, 0], sampleID: 10000))
    for tick in 0..<6 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(10001 + tick))) }
    #expect(game.phase == .airborne && game.attempts == 1)
    cookUntil(&game) { $0.phase == .cooking }
    #expect(game.flips == 1 && game.perfectFlips == 0)
    #expect(game.feedback.contains("Early flip"))
}

@Test("A well-timed upward wrist flick makes a guided full spin and half-turn")
func wokPerfectFlip() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.sear[0] >= 0.61 }
    game.step(deltaTime: 1.0 / 60, input: WokInput(acceleration: [0, 7, -4], gyro: [1, 0, 0], sampleID: 10000))
    for tick in 0..<6 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(10001 + tick))) }
    #expect(game.phase == .airborne)
    #expect(game.lastFlipTurns == 1)
    let firstSide = game.sear[0]
    for tick in 0..<15 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(11000 + tick))) }
    #expect(game.eggPosition.y > 0.5)
    #expect(game.sear[0] == firstSide)
    cookUntil(&game) { $0.phase != .airborne }
    #expect(game.phase == .cooking && game.contactSide == 1)
    #expect(game.flips == 1 && game.perfectFlips == 1)
}

@Test("Every selected doneness can be flipped and served inside its target band", arguments: EggDoneness.allCases)
func wokTargetRound(target: EggDoneness) {
    var game = WokGameEngine(); game.start(target: target)
    for tick in 0..<3600 {
        game.step(deltaTime: 1.0 / 60, input: .autoplay(engine: game, sampleID: UInt64(tick)))
        if game.readyToServe { game.serve(); break }
        if game.finished { break }
    }
    #expect(game.phase == .served)
    #expect(game.rating == 3 && game.flips == 1)
    #expect(target.target.contains(game.sear[1]))
}

@Test("Paused input and long frame gaps neither cook nor create a toss")
func wokPauseAndGaps() {
    var game = WokGameEngine(); game.start(target: .firm)
    cookUntil(&game) { $0.sear[0] > 0.2 }
    let level = game.sear, elapsed = game.elapsed
    game.step(deltaTime: 0.05, input: WokInput(acceleration: [0, 9, 0], gyro: [2, 0, 0], active: false))
    game.step(deltaTime: 5, input: WokInput(acceleration: [0, 9, 0], gyro: [2, 0, 0]))
    #expect(game.sear == level && game.elapsed == elapsed && game.attempts == 0)
}

@Test("Overcooking, premature serving, and excessive tilt have distinct outcomes")
func wokFailureOutcomes() {
    var burnt = WokGameEngine(); burnt.start(target: .soft)
    cookUntil(&burnt) { $0.finished }
    #expect(burnt.phase == .burnt)
    var raw = WokGameEngine(); raw.start(target: .firm)
    cookUntil(&raw) { $0.phase == .cooking }
    raw.serve(); #expect(raw.phase == .served && raw.rating == 1)
    var tipped = WokGameEngine(); tipped.start(target: .medium)
    cookUntil(&tipped) { $0.phase == .cooking }
    for tick in 0..<300 { tipped.step(deltaTime: 1.0 / 60, input: WokInput(rotation: MotionQuaternion(simd_quatf(angle: 1.4, axis: [0, 0, 1])), sampleID: UInt64(tick))) }
    #expect(tipped.phase == .lost)
}

@Test("A flick-triggered flip follows a moving wok and lands on the opposite side")
func wokAssistedCatch() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.sear[0] >= 0.61 }
    game.step(deltaTime: 1.0 / 60, input: WokInput(acceleration: [0, 7, -4], gyro: [1, 0, 0], sampleID: 10000))
    for tick in 0..<6 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(10001 + tick))) }
    let tilt = MotionQuaternion(simd_quatf(angle: 0.2, axis: [0, 0, 1]))
    for tick in 0..<120 {
        let ramp = min(1, Float(tick + 1) / 30)
        game.step(deltaTime: 1.0 / 60, input: WokInput(rotation: tilt, translation: [ramp * 0.4, 0, 0], sampleID: UInt64(11000 + tick)))
        if game.phase == .cooking { break }
    }
    #expect(game.phase == .cooking && game.flips == 1 && game.contactSide == 1)
    #expect(simd_distance(tilt.rotation.inverse.act(game.eggPosition - game.panPosition), [0, WokGameEngine.surfaceHeight(.zero), 0]) < 0.03)
}

@Test("One held upward signal cannot launch the egg multiple times")
func wokGestureRearm() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.sear[0] >= 0.61 }
    for _ in 0..<100 { game.step(deltaTime: 1.0 / 60, input: WokInput(acceleration: [0, 7, -4], gyro: [1, 0, 0], sampleID: 10000)) }
    #expect(game.attempts == 1 && game.flips == 1)
}

@Test("A lateral stirring stroke makes the egg lag behind the moving pan")
func wokStirringInertia() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    for tick in 0..<30 {
        let t = Float(tick + 1) / 60
        game.step(deltaTime: 1.0 / 60, input: WokInput(translation: [1.5 * t * t, 0, 0], acceleration: [3, 0, 0], sampleID: UInt64(tick)))
    }
    #expect(game.eggPosition.x - game.panPosition.x < -0.05)
    #expect(game.phase == .cooking && game.attempts == 0)
}

@Test("A level wok moving in a circle produces an inertial egg orbit in either direction", arguments: [-1.0, 1.0])
func wokFlatCircle(direction: Double) {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    var previous = SIMD2<Float>.zero
    var winding: Float = 0, maxDistance: Float = 0
    for tick in 0..<360 {
        let t = Float(tick + 1) / 60, angle = t * 3 * Float(direction)
        let ramp = min(1, t / 0.5)
        let position = SIMD3<Float>(0.12 * ramp * sin(angle), 0, 0.12 * ramp * (1 - cos(angle)))
        // No tilt and no artificial acceleration input: contact follows actual pan pose.
        game.step(deltaTime: 1.0 / 60, input: WokInput(translation: position, sampleID: UInt64(tick)))
        let local = game.eggPosition - game.panPosition
        let current = SIMD2<Float>(local.x, local.z)
        if tick > 90 { winding += previous.x * current.y - previous.y * current.x }
        previous = current; maxDistance = max(maxDistance, simd_length(current))
        #expect(simd_distance(game.panPosition, position) < 0.00001)
        #expect(game.panRotation == .identity)
        #expect(abs(local.y - WokGameEngine.surfaceHeight(local)) < 0.00001)
        #expect(simd_length(current) <= WokGameEngine.radius - WokGameEngine.eggRadius + 0.0001)
    }
    #expect(maxDistance > 0.05)
    #expect(winding * Float(direction) > 0.05)
    #expect(game.phase == .cooking && game.attempts == 0)
}

@Test("After circular stirring stops, friction and the bowl slope settle the egg")
func wokOrbitSettles() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    for tick in 0..<240 {
        let t = Float(tick + 1) / 60, ramp = min(1, t / 0.5)
        game.step(deltaTime: 1.0 / 60, input: WokInput(translation: [0.16 * ramp * sin(t * 3), 0, 0.16 * ramp * (1 - cos(t * 3))], sampleID: UInt64(tick)))
    }
    let stoppedPan = game.panPosition
    var maximumAfterStop: Float = 0
    for tick in 0..<360 {
        game.step(deltaTime: 1.0 / 60, input: WokInput(translation: stoppedPan, sampleID: UInt64(tick + 1000)))
        let local = game.eggPosition - stoppedPan
        if tick < 120 { maximumAfterStop = max(maximumAfterStop, simd_length(SIMD2(local.x, local.z))) }
    }
    let final = game.eggPosition - stoppedPan
    #expect(simd_length(SIMD2(final.x, final.z)) < maximumAfterStop * 0.5)
    #expect(simd_length(SIMD2(final.x, final.z)) < 0.15)
}

@Test("Gravity calibration maps flat and upright phone movements into the kitchen plane")
func wokGravityFrame() {
    let flat = WokMotionFrame(gravity: MotionVector(x: 0, y: 0, z: -1))
    #expect(simd_distance(flat.deviceToKitchen.rotation.act([0, 0, 1]), [0, 1, 0]) < 0.00001)
    #expect(simd_distance(flat.deviceToKitchen.rotation.act([1, 0, 0]), [1, 0, 0]) < 0.00001)
    #expect(simd_distance(flat.deviceToKitchen.rotation.act([0, 1, 0]), [0, 0, -1]) < 0.00001)
    #expect(abs(flat.wokRotation(.identity).rotation.real - 1) < 0.00001)
    let upright = WokMotionFrame(gravity: MotionVector(x: 0, y: -1, z: 0))
    #expect(abs(upright.deviceToKitchen.rotation.real - 1) < 0.00001)
}

@Test("Wok translation follows estimated metres directly and holds when stationary")
func wokDirectTranslation() {
    var tracker = WokTranslationTracker()
    let estimate = MotionEstimate(velocity: MotionVector(x: 0.2, y: 0, z: -0.1), isAvailable: true)
    for tick in 0...60 { _ = tracker.update(estimate, timestamp: Double(tick) / 60) }
    #expect(simd_distance(tracker.displacement, [0.2, 0, -0.1]) < 0.0001)
    _ = tracker.update(MotionEstimate(isAvailable: true), timestamp: 61.0 / 60)
    let stopped = tracker.displacement
    for tick in 62...120 { _ = tracker.update(MotionEstimate(isAvailable: true), timestamp: Double(tick) / 60) }
    #expect(tracker.displacement == stopped)
    tracker.reset(); #expect(tracker.displacement == .zero)
}

@Test("Manual recentering moves the stationary egg with the bowl without a phantom throw")
func wokRecenterContact() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    for tick in 0..<60 {
        game.step(deltaTime: 1.0 / 60, input: WokInput(translation: [Float(tick + 1) * 0.005, 0, 0], sampleID: UInt64(tick)))
    }
    let relative = game.eggPosition - game.panPosition
    game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: 1000, recenterID: 1))
    #expect(simd_distance(game.eggPosition - game.panPosition, relative) < 0.01)
    #expect(game.phase == .cooking && game.attempts == 0)
}

@Test("Phone screen inclination is preserved rather than reset to a level wok")
func wokScreenIsOpening() {
    for gravity in [MotionVector(x: 0, y: -1, z: 0), MotionVector(x: 0.3, y: -0.4, z: -0.8660254)] {
        let frame = WokMotionFrame(gravity: gravity)
        let opening = frame.wokRotation(.identity).rotation.act(SIMD3<Float>(0, 1, 0))
        let phoneNormal = frame.deviceToKitchen.rotation.act(SIMD3<Float>(0, 0, 1))
        #expect(simd_distance(opening, phoneNormal) < 0.00001)
        #expect(abs(opening.y + Float(gravity.z / gravity.magnitude)) < 0.00001)
    }
}

@Test("Flick classification uses the peak and rejects flat circles and yaw-only motion")
func wokFlickPeaks() throws {
    var detector = WokFlickDetector()
    #expect(detector.update(WokInput(acceleration: [0, 4, -3], gyro: [0.6, 0, 0], sampleID: 1), time: 0) == nil)
    #expect(detector.update(WokInput(acceleration: [0, 14, -8], gyro: [4.5, 0, 0], sampleID: 2), time: 0.04) == nil)
    let peakEvent = detector.update(WokInput(sampleID: 3), time: 0.09)
    let fast = try #require(peakEvent)
    #expect(fast.spins == 2)
    detector.reset()
    for tick in 0..<120 {
        let t = Float(tick) / 60
        #expect(detector.update(WokInput(acceleration: [cos(t) * 5, 0, sin(t) * 5], gyro: [0, 5, 0], sampleID: UInt64(tick)), time: Double(t)) == nil)
    }
    #expect(detector.update(WokInput(acceleration: [0, 5, 0], gyro: [0, 4, 0], sampleID: 1000), time: 3) == nil)
}

@Test("Normal and fast flicks spin once or twice and both finish on the opposite side", arguments: [1, 2])
func wokOneAndTwoSpins(spins: Int) {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.sear[0] >= 0.61 }
    let gesture = WokInput(acceleration: [0, spins == 2 ? 14 : 7, spins == 2 ? -8 : -4], gyro: [spins == 2 ? 4.5 : 1, 0, 0], sampleID: 10000)
    for _ in 0..<8 { game.step(deltaTime: 1.0 / 60, input: gesture) }
    #expect(game.phase == .airborne && game.lastFlipTurns == spins)
    cookUntil(&game) { $0.phase == .cooking }
    #expect(game.contactSide == 1 && game.flips == 1 && game.totalTurns == spins)
    #expect(game.perfectFlips == 1)
    #expect(simd_dot(game.eggRotation.rotation.act(SIMD3<Float>(0, 1, 0)), [0, 1, 0]) < -0.99)
}

@Test("Practice mode supports repeated single and double flips without overcooking")
func wokPracticePlayground() {
    var game = WokGameEngine(); game.start(target: .medium, practice: true)
    let initial = game.sear
    for tick in 0..<1800 {
        game.step(deltaTime: 1.0 / 60, input: .autoplay(engine: game, sampleID: UInt64(tick)))
    }
    #expect(game.phase == .cooking || game.phase == .airborne)
    #expect(game.practiceMode && game.sear == initial)
    #expect(game.flips >= 3 && game.totalTurns > game.flips)
}

@Test("Turning a wok upside down releases the egg instead of sticking it to the surface")
func wokUpsideDownRelease() {
    var game = WokGameEngine(); game.start(target: .medium, practice: true)
    cookUntil(&game) { $0.phase == .cooking }
    for tick in 0..<120 {
        let angle = min(1, Float(tick + 1) / 60) * Float.pi
        game.step(deltaTime: 1.0 / 60, input: WokInput(rotation: MotionQuaternion(simd_quatf(angle: angle, axis: [1, 0, 0])), sampleID: UInt64(tick)))
    }
    #expect(game.phase == .lost)
    #expect(game.eggPosition.y <= -0.49)
}

@Test("A forward push followed by an upward lift triggers; upward-only and stale pushes do not")
func wokPushThenLiftGesture() throws {
    var detector = WokFlickDetector()
    #expect(detector.update(WokInput(acceleration: [0, 0, -4], sampleID: 1), time: 0) == nil)
    #expect(detector.update(WokInput(acceleration: [0, 7, 0], sampleID: 2), time: 0.15) == nil)
    let gesture = detector.update(WokInput(sampleID: 3), time: 0.25)
    let result = try #require(gesture)
    #expect(result.spins == 1)
    detector.reset()
    for tick in 0..<20 {
        #expect(detector.update(WokInput(acceleration: [0, 14, 0], gyro: [5, 0, 0], sampleID: UInt64(tick)), time: Double(tick) / 60) == nil)
    }
    detector.reset()
    #expect(detector.update(WokInput(acceleration: [0, 0, -4], sampleID: 1), time: 0) == nil)
    #expect(detector.update(WokInput(acceleration: [0, 7, 0], sampleID: 2), time: 0.5) == nil)
    #expect(detector.update(WokInput(sampleID: 3), time: 0.7) == nil)
}
