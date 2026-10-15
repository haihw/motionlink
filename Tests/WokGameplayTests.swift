import simd
import Testing
@testable import MotionLinkCore

private func cookUntil(_ engine: inout WokGameEngine, _ condition: (WokGameEngine) -> Bool) {
    for index in 0..<3600 {
        if condition(engine) { return }
        engine.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(index)))
    }
}

private func tossEgg(_ game: inout WokGameEngine, big: Bool = false) {
    let sequence = UInt64(10000 + game.attempts * 100)
    game.step(deltaTime: 1.0 / 60, input: WokInput(acceleration: [0, big ? 14 : 7, -4], gyro: [1, 0, 0], sampleID: sequence))
    for tick in 1...6 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: sequence + UInt64(tick))) }
}

private func cookedEgg(target: EggDoneness = .medium) -> WokGameEngine {
    var game = WokGameEngine(); game.start(target: target)
    cookUntil(&game) { $0.sear[0] >= 0.61 }
    tossEgg(&game)
    cookUntil(&game) { $0.readyToServe }
    return game
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

@Test("Overcooking and excessive tilt have distinct outcomes")
func wokFailureOutcomes() {
    var burnt = WokGameEngine(); burnt.start(target: .soft)
    cookUntil(&burnt) { $0.finished }
    #expect(burnt.phase == .burnt)
    var tipped = WokGameEngine(); tipped.start(target: .medium)
    cookUntil(&tipped) { $0.phase == .cooking }
    for tick in 0..<300 { tipped.step(deltaTime: 1.0 / 60, input: WokInput(rotation: MotionQuaternion(simd_quatf(angle: 1.4, axis: [0, 0, 1])), sampleID: UInt64(tick))) }
    #expect(tipped.phase == .lost)
}

@Test("A big toss serves only when both egg faces reach their cooking thresholds", arguments: [false, true])
func wokBigTossBeforeReady(firstSideDone: Bool) {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { firstSideDone ? $0.sear[0] >= 0.61 : $0.phase == .cooking }
    if firstSideDone {
        tossEgg(&game)
        cookUntil(&game) { $0.phase == .cooking }
    }
    #expect(!game.readyToServe)
    tossEgg(&game, big: true)
    #expect(game.phase == .airborne && game.lastFlipTurns == 2)
    #expect(!game.finished)
}

@Test("Cooking the second face alone cannot unlock serving", arguments: EggDoneness.allCases)
func wokBothFacesRequired(target: EggDoneness) {
    var game = WokGameEngine(); game.start(target: target)
    cookUntil(&game) { $0.sear[0] >= 0.25 }
    tossEgg(&game)
    cookUntil(&game) { $0.sear[1] >= target.target.lowerBound + 0.02 }
    #expect(!game.readyToServe)
    tossEgg(&game, big: true)
    #expect(game.phase == .airborne && !game.finished)
}

@Test("A normal toss still flips a cooked egg rather than serving it")
func wokNormalTossWhenReady() {
    var game = cookedEgg()
    #expect(game.readyToServe)
    tossEgg(&game)
    #expect(game.phase == .airborne && game.lastFlipTurns == 1)
    cookUntil(&game) { $0.phase == .cooking }
    #expect(game.flips == 2 && !game.finished)
}

@Test("A serving toss freezes heat and catches upright on the fixed plate despite wok movement")
func wokServingPlateCatch() {
    var game = cookedEgg()
    tossEgg(&game, big: true)
    #expect(game.phase == .serving && !game.finished && game.flips == 1)
    let sear = game.sear, start = game.eggPosition
    for tick in 0..<24 {
        game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(30000 + tick)))
    }
    #expect(game.eggPosition.y > start.y + 0.7)
    #expect(game.eggPosition.x > start.x && game.eggPosition.x < WokGameEngine.plateCatchPosition.x)
    #expect(game.sear == sear && !game.finished)
    for tick in 0..<90 {
        game.step(deltaTime: 1.0 / 60, input: WokInput(rotation: MotionQuaternion(simd_quatf(angle: 0.3, axis: [1, 0, 0])), translation: [-0.2, 0.1, -0.1], sampleID: UInt64(40000 + tick)))
    }
    #expect(game.phase == .served && game.finished && game.rating == 3)
    #expect(game.sear == sear && game.flips == 1)
    #expect(game.eggPosition == WokGameEngine.plateCatchPosition)
    #expect(game.eggRotation == .identity)
    #expect(simd_distance(game.panPosition, game.eggPosition) > 1)
    #expect(game.feedback.contains("plate"))
    game.step(deltaTime: 0.05, input: WokInput(translation: [0.2, 0, 0], sampleID: 50000))
    #expect(game.eggPosition == WokGameEngine.plateCatchPosition && game.attempts == 2)
}

@Test("An egg past the ideal band can still be served with a lower timing score")
func wokLatePlateCatch() {
    var game = cookedEgg(target: .soft)
    cookUntil(&game) { $0.sear[1] >= 0.40 }
    #expect(game.readyToServe)
    tossEgg(&game, big: true)
    #expect(game.phase == .serving)
    cookUntil(&game) { $0.finished }
    #expect(game.phase == .served && game.rating == 1)
    #expect(game.feedback.contains("Past the target"))
}

@Test("Pausing a serving flight waits for fresh input before completing the plate catch")
func wokServingPause() {
    var game = cookedEgg(); tossEgg(&game, big: true)
    let position = game.eggPosition, elapsed = game.elapsed
    game.step(deltaTime: 0.05, input: WokInput(active: false))
    game.step(deltaTime: 5, input: WokInput())
    #expect(game.phase == .serving && game.eggPosition == position && game.elapsed == elapsed)
    cookUntil(&game) { $0.finished }
    #expect(game.phase == .served)
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
    let estimate = MotionEstimate(velocity: MotionVector(x: 0.08, y: 0, z: -0.04), isAvailable: true)
    for tick in 0...60 { _ = tracker.update(estimate, timestamp: Double(tick) / 60) }
    #expect(simd_distance(tracker.displacement, [0.08, 0, -0.04]) < 0.0001)
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

@Test("The wok stays in a circular stove support range and cannot sink below it")
func wokStoveRange() {
    var tracker = WokTranslationTracker()
    for tick in 0...300 {
        _ = tracker.update(MotionEstimate(velocity: MotionVector(x: 2, y: -1, z: 2), isAvailable: true), timestamp: Double(tick) / 60)
        let offset = tracker.displacement
        #expect(simd_length(SIMD2<Float>(offset.x, offset.z)) <= WokTranslationTracker.horizontalLimit + 0.000001)
        #expect(offset.y == 0)
    }
    #expect(simd_length(SIMD2<Float>(tracker.displacement.x, tracker.displacement.z)) > 0.20)
    for tick in 301...600 {
        _ = tracker.update(MotionEstimate(velocity: MotionVector(x: 0, y: 2, z: 0), isAvailable: true), timestamp: Double(tick) / 60)
        #expect(tracker.displacement.y <= WokTranslationTracker.liftLimit + 0.000001)
    }
    #expect(tracker.displacement.y > 0.11)
}

@Test("The stove edge resists outward movement and reverses immediately without windup")
func wokSoftEdgeAndReverse() {
    var tracker = WokTranslationTracker()
    let outward = MotionEstimate(velocity: MotionVector(x: 0.3, y: 0, z: 0), isAvailable: true)
    var earlyStep: Float = 0, lateStep: Float = 0
    for tick in 0...300 {
        let before = tracker.displacement.x
        _ = tracker.update(outward, timestamp: Double(tick) / 60)
        if tick == 10 { earlyStep = tracker.displacement.x - before }
        if tick == 300 { lateStep = tracker.displacement.x - before }
    }
    #expect(earlyStep > 0.004)
    #expect(lateStep < earlyStep * 0.1)
    let edge = tracker.displacement.x
    let inward = MotionEstimate(velocity: MotionVector(x: -0.3, y: 0, z: 0), isAvailable: true)
    _ = tracker.update(inward, timestamp: 301.0 / 60)
    _ = tracker.update(inward, timestamp: 302.0 / 60)
    #expect(tracker.displacement.x < edge - 0.004)
}

@Test("Circular stirring remains responsive inside the stove's free range")
func wokSmallCircleRange() {
    var tracker = WokTranslationTracker()
    let angularSpeed: Float = 3, radius: Float = 0.05
    for tick in 0...360 {
        let t = Float(tick) / 60
        let velocity = SIMD3<Float>(radius * angularSpeed * cos(t * angularSpeed), 0, radius * angularSpeed * sin(t * angularSpeed))
        let position = tracker.update(MotionEstimate(velocity: MotionVector(velocity), isAvailable: true), timestamp: Double(tick) / 60)
        let expected = SIMD3<Float>(radius * sin(t * angularSpeed), 0, radius * (1 - cos(t * angularSpeed)))
        #expect(simd_distance(position, expected) < 0.0001)
    }
}

@Test("An egg resting in a level wok heats at exactly twice the normal rate")
func wokRestingDoubleHeat() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    for tick in 0..<30 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(4000 + tick))) }
    #expect(game.heatingMultiplier == 2)
    let before = game.sear[0]
    for tick in 0..<60 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(5000 + tick))) }
    #expect(abs((game.sear[0] - before) - 0.10) < 0.00001)
    #expect(game.phase == .cooking && game.heatingMultiplier == 2)
}

@Test("Circular stirring keeps normal heat while the egg slides relative to the bowl")
func wokStirringNormalHeat() {
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.phase == .cooking }
    let before = game.sear[0]
    var normalHeatFrames = 0
    for tick in 0..<180 {
        let time = Float(tick + 1) / 60, angle = time * 3
        let ramp = min(1, time / 0.5)
        let position = SIMD3<Float>(0.12 * ramp * sin(angle), 0, 0.12 * ramp * (1 - cos(angle)))
        game.step(deltaTime: 1.0 / 60, input: WokInput(translation: position, sampleID: UInt64(10000 + tick)))
        if game.heatingMultiplier == 1 { normalHeatFrames += 1 }
    }
    #expect(normalHeatFrames > 150)
    #expect(game.sear[0] - before < 0.17)
    #expect(game.phase == .cooking)
}

@Test("Resting bonus never heats an airborne egg or a heat-off practice egg")
func wokDoubleHeatContactOnly() {
    var practice = WokGameEngine(); practice.start(target: .medium, practice: true)
    let initial = practice.sear
    for tick in 0..<600 { practice.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(tick))) }
    #expect(practice.sear == initial && practice.heatingMultiplier == 0)
    var game = WokGameEngine(); game.start(target: .medium)
    cookUntil(&game) { $0.sear[0] >= 0.61 }
    #expect(game.heatingMultiplier == 2)
    tossEgg(&game)
    #expect(game.phase == .airborne && game.heatingMultiplier == 0)
    let sear = game.sear
    for tick in 0..<20 { game.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(30000 + tick))) }
    #expect(game.sear == sear && game.heatingMultiplier == 0)
}
