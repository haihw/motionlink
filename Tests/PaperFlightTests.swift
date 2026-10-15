import simd
import Testing
@testable import MotionLinkCore

private func flightSample(_ tick: Int, fps: Double = 60, roll: Float = 0, forwardTilt: Float = 0, acceleration: SIMD3<Float> = .zero) -> MotionSample {
    let gravity = simd_normalize(SIMD3<Float>(tan(roll), tan(forwardTilt), -1))
    let rotation = simd_quatf(from: gravity, to: SIMD3<Float>(0, 0, -1))
    return MotionSample(sequence: UInt64(tick), timestamp: Double(tick) / fps, attitude: MotionQuaternion(rotation),
                        rotationRate: .zero, acceleration: MotionVector(rotation.inverse.act(acceleration)), gravity: MotionVector(gravity))
}
private func launchedFlight(fps: Double = 60) -> (PaperFlightEngine, Int) {
    var engine = PaperFlightEngine(); engine.calibrate(flightSample(0, fps: fps)); engine.launch()
    var tick = 0
    while engine.phase == .countdown && tick < Int(fps * 4) { tick += 1; engine.update(flightSample(tick, fps: fps)) }
    return (engine, tick)
}

@Test("Flight requires a calibrated grip and three seconds of relaxed neutral")
func flightLaunchCountdown() {
    var engine = PaperFlightEngine()
    let uncalibrated = engine.launch()
    #expect(!uncalibrated)
    engine.calibrate(flightSample(0)); engine.launch()
    for tick in 1...100 { engine.update(flightSample(tick, roll: 0.03)) }
    #expect(engine.phase == .countdown && engine.countdown < 1.4)
    engine.update(flightSample(101, roll: 0.3))
    #expect(engine.countdown == 3 && engine.position == SIMD3<Float>(0, 8, 0))
    var launches = 0
    for tick in 102...290 { launches += engine.update(flightSample(tick)).filter { $0 == .launched }.count }
    #expect(launches == 1 && engine.phase == .flying && engine.elapsed > 0)
    engine.launch()
    for tick in 291...350 { engine.update(flightSample(tick)) }
    #expect(engine.countdown < 2.1)
    engine.update(flightSample(410))
    #expect(engine.phase == .countdown && engine.countdown == 3)
}

@Test("Steady screen-up auto-calibration allows small hand motion")
func flightAutoCalibration() {
    var engine = PaperFlightEngine()
    var calibrations = 0
    for tick in 0...60 { calibrations += engine.update(flightSample(tick, roll: 0.025)).filter { $0 == .calibrated }.count }
    #expect(calibrations == 1 && engine.isCalibrated && engine.phase == .ready)
    #expect(engine.position == SIMD3<Float>(0, 8, 0))
}

@Test("Banking produces correctly signed turns; pitch controls climb and dive", arguments: [Float(-0.2), 0.2])
func flightControlAxes(angle: Float) {
    var (banked, tick) = launchedFlight()
    for _ in 0..<60 { tick += 1; banked.update(flightSample(tick, roll: angle)) }
    #expect(banked.heading * angle > 0 && banked.position.x * angle > 0)
    #expect(banked.bank * angle > 0)
    var (pitched, pitchTick) = launchedFlight()
    for _ in 0..<60 { pitchTick += 1; pitched.update(flightSample(pitchTick, forwardTilt: angle)) }
    #expect((pitched.position.y - 8) * angle < 0 && pitched.pitch * angle < 0)
    #expect(simd_distance(pitched.orientation.rotation.act([0, 0, -1]), pitched.forward) < 0.0001)
}

@Test("Upright grip uses gravity-aligned left and forward axes")
func flightUprightPose() {
    var engine = PaperFlightEngine()
    let reference = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
    var sample = flightSample(0); sample.attitude = MotionQuaternion(reference); sample.gravity = MotionVector(x: 0, y: -1, z: 0)
    let captured = engine.calibrate(sample)
    #expect(captured)
    engine.launch()
    for tick in 1...185 {
        sample.sequence = UInt64(tick); sample.timestamp = Double(tick) / 60
        engine.update(sample)
    }
    for tick in 186...245 {
        sample.sequence = UInt64(tick); sample.timestamp = Double(tick) / 60
        sample.attitude = MotionQuaternion(reference * simd_quatf(angle: -0.2, axis: SIMD3<Float>(0, 0, 1)))
        engine.update(sample)
    }
    #expect(engine.phase == .flying && engine.heading > 0 && engine.position.x > 0)
}

@Test("Flight integration remains consistent across sensor rates")
func flightFrameRates() {
    var positions: [SIMD3<Float>] = []
    for fps in [30.0, 60, 120] {
        var (engine, tick) = launchedFlight(fps: fps)
        for _ in 0..<Int(fps * 2) { tick += 1; engine.update(flightSample(tick, fps: fps, roll: 0.15, forwardTilt: -0.1)) }
        positions.append(engine.position)
        #expect(engine.phase == .flying)
    }
    #expect(simd_distance(positions[0], positions[2]) < 0.03)
    #expect(simd_distance(positions[1], positions[2]) < 0.03)
}

@Test("Forward flick boosts once; backward motion and sustained acceleration do not retrigger")
func flightBoostGesture() {
    var (engine, tick) = launchedFlight()
    tick += 1; let backward = engine.update(flightSample(tick, acceleration: [0, -1, 0]))
    #expect(!backward.contains(.boost) && engine.boostCount == 0)
    tick += 1; let forward = engine.update(flightSample(tick, acceleration: [0, 0.9, 0]))
    #expect(forward.contains(.boost) && engine.boostCount == 1)
    for _ in 0..<180 { tick += 1; engine.update(flightSample(tick, acceleration: [0, 0.9, 0])) }
    #expect(engine.boostCount == 1 && engine.boostRemaining == 0)
    for _ in 0..<20 { tick += 1; engine.update(flightSample(tick)) }
    tick += 1; let retrigger = engine.update(flightSample(tick, acceleration: [0, 0.9, 0]))
    #expect(retrigger.contains(.boost) && engine.boostCount == 2)
}

@Test("Ring centers earn perfect bonuses, other safe passes score, and missed rings do not")
func flightRingScoring() {
    var (perfect, _) = launchedFlight()
    let event = perfect.checkSegment(from: [0, 8, -34], to: [0, 8, -36])
    #expect(event == [.ringPassed(0, perfect: true)] && perfect.score == 150 && perfect.nextRing == 1)
    perfect.checkSegment(from: [0, 8, -34], to: [0, 8, -36])
    #expect(perfect.score == 150)
    var (pass, _) = launchedFlight()
    pass.checkSegment(from: [2.5, 8, -34], to: [2.5, 8, -36])
    #expect(pass.results[0] == .passed && pass.score == 100)
    var (miss, _) = launchedFlight()
    let missed = miss.checkSegment(from: [9, 8, -34], to: [9, 8, -36])
    #expect(missed == [.ringMissed(0)] && miss.score == 0 && miss.phase == .flying)
}

@Test("Swept collisions catch high-speed storm crossings and rim grazes before their center plane")
func flightSweptCollisions() {
    var (storm, _) = launchedFlight()
    let events = storm.checkSegment(from: [6, 8, -45], to: [6, 8, -65])
    #expect(events == [.crashed(.storm)] && storm.position.z > -54)
    var (rim, _) = launchedFlight()
    let graze = rim.checkSegment(from: [4.8, 8, -31], to: [4.8, 8, -34.5])
    #expect(graze == [.crashed(.ring)] && rim.position.z > -35)
    var (side, _) = launchedFlight()
    let sideHit = side.checkSegment(from: [0, 8, -35], to: [8, 8, -35])
    #expect(sideHit == [.crashed(.ring)])
    var (water, _) = launchedFlight()
    let ground = water.checkSegment(from: [0, 8, -2], to: [0, -5, -10])
    #expect(ground == [.crashed(.ground)] && abs(water.position.y - PaperFlightEngine.bodyRadius) < 0.001)
}

@Test("Course completion freezes scoring; restart keeps calibration and clears the flight")
func flightFinishRestart() {
    var (engine, tick) = launchedFlight()
    let id = engine.flightID; engine.sensitivity = 1.2
    var finishes = 0
    for ring in engine.course.rings {
        finishes += engine.checkSegment(from: ring.center + [0, 0, 1], to: ring.center - [0, 0, 1]).filter { $0 == .finished }.count
    }
    #expect(engine.phase == .finished && engine.ringsPassed == 8 && engine.score == 1200 && finishes == 1)
    let position = engine.position, time = engine.elapsed
    for _ in 0..<30 { tick += 1; engine.update(flightSample(tick, roll: 0.5)) }
    #expect(engine.position == position && engine.elapsed == time && engine.score == 1200)
    engine.launch()
    #expect(engine.phase == .countdown && engine.score == 0 && engine.flightID != id && engine.isCalibrated && engine.sensitivity == 1.2)
}

@Test("Duplicate, delayed, and disconnected sensor frames cannot advance the plane")
func flightSensorLifecycle() {
    var (engine, tick) = launchedFlight()
    tick += 1; engine.update(flightSample(tick))
    let position = engine.position
    for _ in 0..<50 { engine.update(flightSample(tick, roll: 0.8)) }
    #expect(engine.position == position)
    tick += 60; engine.update(flightSample(tick, roll: 0.3))
    #expect(engine.position == position && engine.neutralProgress == 0)
    tick += 1; engine.update(flightSample(tick, roll: 0.3))
    #expect(engine.position == position)
    engine.suspend()
    #expect(!engine.isCalibrated && !engine.isTracking && engine.position == position)
    for _ in 0..<60 { tick += 1; engine.update(flightSample(tick)) }
    #expect(engine.isCalibrated && engine.position.z <= position.z && simd_distance(engine.position, position) < 3)
}

@Test("Guided preview flies the actual course with all rings, a boost, and no collisions", arguments: [Float(0.5), 1, 1.5])
func flightGuidedPreview(sensitivity: Float) {
    var preview = PaperFlightPreview(sensitivity: sensitivity)
    for _ in 0..<4200 {
        preview.tick()
        if preview.engine.phase == .crashed || preview.engine.phase == .finished { break }
    }
    #expect(preview.engine.phase == .finished)
    #expect(preview.engine.ringsPassed == 8 && preview.engine.boostCount == 1)
    #expect(preview.engine.elapsed > 25 && preview.engine.elapsed < 50)
}
