import simd
import Testing
@testable import MotionLinkCore

private func drawingRotation(right: Float = 0, forward: Float = 0) -> MotionQuaternion {
    MotionQuaternion(simd_quatf(angle: right * .pi / 180, axis: SIMD3<Float>(0, 1, 0))
        * simd_quatf(angle: -forward * .pi / 180, axis: SIMD3<Float>(1, 0, 0)))
}
private func drawingSample(_ tick: Int, hz: Double = 60, rotation: MotionQuaternion = .identity,
                           acceleration: MotionVector = .zero, gravity: MotionVector = MotionVector(x: 0, y: 0, z: -1)) -> MotionSample {
    MotionSample(sequence: UInt64(tick), timestamp: Double(tick) / hz, attitude: rotation,
                 rotationRate: .zero, acceleration: acceleration, gravity: gravity)
}
private func drawingEngine() -> DrawingEngine {
    var engine = DrawingEngine(); engine.configureTrigger(.init(angle: 45)); engine.calibrate(drawingSample(0)); return engine
}
@discardableResult private func drawingToggle(_ engine: inout DrawingEngine, from start: Int) -> Int {
    for tick in start..<(start + 60) {
        let phase = tick - start
        let angle = engine.triggerSettings.angle + 5
        let roll: Float = (10..<16).contains(phase) ? -angle : (16..<22).contains(phase) ? angle : 0
        engine.update(drawingSample(tick, rotation: drawingRotation(right: roll)))
    }
    return start + 60
}

@Test("Tilt follows all cardinal directions and the requested up-left diagonal")
func drawingDirections() {
    for (right, forward) in [(Float(-20), Float(0)), (20, 0), (0, 20), (0, -20), (-20, 20), (20, -20)] {
        var engine = drawingEngine()
        for tick in 1...30 { engine.update(drawingSample(tick, rotation: drawingRotation(right: right, forward: forward))) }
        let travel = engine.position - DrawingEngine.paperSize / 2
        #expect(right == 0 ? abs(travel.x) < 0.001 : travel.x * right > 0)
        #expect(forward == 0 ? abs(travel.y) < 0.001 : travel.y * forward < 0)
        if right == -20 && forward == 20 { #expect(travel.x < 0 && travel.y < 0) }
        #expect(engine.strokes.isEmpty) // Moving a lifted tool never makes marks.
    }
}

@Test("Larger tilts move faster, neutral tremor stays still, and yaw alone gives no force")
func drawingTiltPhysics() {
    var slow = drawingEngine(), fast = drawingEngine(), tremor = drawingEngine(), yaw = drawingEngine()
    for tick in 1...20 {
        slow.update(drawingSample(tick, rotation: drawingRotation(right: 10)))
        fast.update(drawingSample(tick, rotation: drawingRotation(right: 30)))
        tremor.update(drawingSample(tick, rotation: drawingRotation(right: 0.8, forward: -0.6)))
        yaw.update(drawingSample(tick, rotation: MotionQuaternion(simd_quatf(angle: 1.2, axis: SIMD3<Float>(0, 0, 1)))))
    }
    #expect(fast.speed > slow.speed * 2)
    #expect(fast.position.x > slow.position.x)
    #expect(tremor.position == DrawingEngine.paperSize / 2 && tremor.speed == 0)
    #expect(yaw.position == DrawingEngine.paperSize / 2 && yaw.speed == 0)
}

@Test("Diagonal movement preserves gravity direction and has no artificial speed boost")
func drawingDiagonalSpeed() {
    let angle: Float = 0.4
    let axis = simd_normalize(SIMD3<Float>(1, -1, 0))
    var diagonal = drawingEngine(), cardinal = drawingEngine()
    for tick in 1...20 {
        diagonal.update(drawingSample(tick, rotation: MotionQuaternion(simd_quatf(angle: angle, axis: axis))))
        cardinal.update(drawingSample(tick, rotation: MotionQuaternion(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0)))))
    }
    #expect(abs(diagonal.speed - cardinal.speed) < 0.01)
    #expect(abs(abs(diagonal.velocity.x) - abs(diagonal.velocity.y)) < 0.01)
}

@Test("Constant tilt produces the same travel at 30, 60, and 120 Hz")
func drawingSensorRates() {
    var positions: [SIMD2<Float>] = []
    for hz in [30, 60, 120] {
        var engine = drawingEngine()
        for tick in 1...hz { engine.update(drawingSample(tick, hz: Double(hz), rotation: drawingRotation(right: 18, forward: 12))) }
        positions.append(engine.position)
    }
    #expect(simd_distance(positions[0], positions[1]) < 0.05)
    #expect(simd_distance(positions[1], positions[2]) < 0.05)
}

@Test("A comfortable tilted reference stays still and relative tilt still steers")
func drawingComfortableReference() {
    var engine = DrawingEngine()
    let reference = drawingRotation(right: 12, forward: -15)
    let calibrated = engine.calibrate(drawingSample(0, rotation: reference))
    #expect(calibrated)
    for tick in 1...30 { engine.update(drawingSample(tick, rotation: reference)) }
    #expect(engine.position == DrawingEngine.paperSize / 2)
    let current = MotionQuaternion(reference.rotation * drawingRotation(right: -20).rotation)
    for tick in 31...60 { engine.update(drawingSample(tick, rotation: current)) }
    #expect(engine.position.x < 500 && abs(engine.position.y - 375) < 0.01)
}

@Test("Automatic setup requires a brief steady screen-up pose and resets on motion")
func drawingAutomaticSetup() {
    var engine = DrawingEngine()
    for tick in 0..<30 { engine.update(drawingSample(tick)) }
    #expect(!engine.isCalibrated && engine.calibrationProgress > 0)
    engine.update(drawingSample(30, acceleration: MotionVector(x: 0.3, y: 0, z: 0)))
    #expect(engine.calibrationProgress == 0)
    for tick in 31..<80 { engine.update(drawingSample(tick)) }
    #expect(engine.isCalibrated && !engine.isPenDown)
    var upsideDown = drawingSample(80); upsideDown.gravity.z = 1
    let invertedCalibration = engine.calibrate(upsideDown)
    #expect(invertedCalibration) // An explicit capture permits any steady grip.
}

@Test("Manual natural pose accepts flat, inclined, upright, and inverted steady grips", arguments: [Float(0), 35, 90, 145, 180])
func drawingNaturalPose(inclination: Float) {
    var engine = DrawingEngine()
    let pose = MotionQuaternion(simd_quatf(angle: inclination * .pi / 180, axis: SIMD3<Float>(1, 0, 0)))
    let gravity = MotionVector(pose.rotation.inverse.act(SIMD3<Float>(0, 0, -1)))
    let sample = drawingSample(0, rotation: pose, gravity: gravity)
    let captured = engine.calibrate(sample)
    #expect(captured)
    for tick in 1...30 { engine.update(drawingSample(tick, rotation: pose, gravity: gravity)) }
    #expect(engine.isTracking && engine.isCalibrated && engine.speed == 0)
    #expect(engine.position == DrawingEngine.paperSize / 2 && simd_length(engine.tiltDegrees) < 0.001)
}

@Test("An upright natural grip steers with sideways lean and forward tilt; yaw does not steer")
func drawingUprightSteering() {
    let pose = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
    let gravity = MotionVector(x: 0, y: -1, z: 0)
    for axis in [SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0), SIMD3<Float>(0, 1, 0)] {
        var engine = DrawingEngine()
        engine.calibrate(drawingSample(0, rotation: MotionQuaternion(pose), gravity: gravity))
        let tilted = MotionQuaternion(pose * simd_quatf(angle: 0.3, axis: axis))
        for tick in 1...30 { engine.update(drawingSample(tick, rotation: tilted, gravity: gravity)) }
        if axis.z == -1 { #expect(engine.position.x > 500 && abs(engine.position.y - 375) < 0.01) }
        else if axis.x == -1 { #expect(engine.position.y < 375 && abs(engine.position.x - 500) < 0.01) }
        else { #expect(engine.position == DrawingEngine.paperSize / 2 && engine.speed == 0) }
    }
}

@Test("Left-right trigger works relative to an upright natural pose")
func drawingUprightTrigger() {
    var engine = DrawingEngine()
    let pose = simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
    let gravity = MotionVector(x: 0, y: -1, z: 0)
    engine.calibrate(drawingSample(0, rotation: MotionQuaternion(pose), gravity: gravity))
    var toggles = 0
    for tick in 1...60 {
        let angle: Float = (6..<12).contains(tick) ? 25 : (12..<18).contains(tick) ? -25 : 0
        let attitude = MotionQuaternion(pose * simd_quatf(angle: angle * .pi / 180, axis: SIMD3<Float>(0, 0, 1)))
        if engine.update(drawingSample(tick, rotation: attitude, gravity: gravity)) == .penDown { toggles += 1 }
    }
    #expect(toggles == 1 && engine.isPenDown && !engine.isSettling)
    #expect(engine.position == DrawingEngine.paperSize / 2)
}

@Test("Capturing a natural pose lifts the tip while preserving position, artwork, and trigger settings")
func drawingNaturalPosePreservesPaper() {
    var engine = drawingEngine()
    let next = drawingToggle(&engine, from: 1)
    for tick in next..<(next + 20) { engine.update(drawingSample(tick, rotation: drawingRotation(right: 20))) }
    let points = engine.pointCount, strokes = engine.strokes.map(\.id), position = engine.position, settings = engine.triggerSettings
    #expect(points > 1 && engine.isPenDown)
    let pose = MotionQuaternion(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)))
    let captured = engine.calibrate(drawingSample(next + 20, rotation: pose, gravity: MotionVector(x: 0, y: -1, z: 0)))
    #expect(captured && engine.isCalibrated && !engine.isPenDown && engine.speed == 0)
    #expect(engine.pointCount == points && engine.strokes.map(\.id) == strokes && engine.position == position)
    #expect(engine.triggerSettings == settings && engine.tiltDegrees == .zero)
}

@Test("Upright grips require explicit capture; moving and invalid samples cannot capture")
func drawingNaturalPoseReadiness() {
    var engine = DrawingEngine()
    let pose = MotionQuaternion(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)))
    for tick in 0...60 { engine.update(drawingSample(tick, rotation: pose, gravity: MotionVector(x: 0, y: -1, z: 0))) }
    #expect(!engine.isCalibrated)
    var sample = drawingSample(61, rotation: pose, gravity: MotionVector(x: 0, y: -1, z: 0))
    #expect(DrawingEngine.canCalibrate(sample))
    sample.rotationRate.x = 1
    let moving = engine.calibrate(sample)
    #expect(!moving && !engine.isCalibrated)
    sample.rotationRate = .zero; sample.gravity = .zero
    #expect(!DrawingEngine.canCalibrate(sample))
    sample.gravity = MotionVector(x: 0, y: -1, z: 0); sample.acceleration.x = 0.5
    #expect(!DrawingEngine.canCalibrate(sample))
}

@Test("Left-then-right tilt toggles drawing; acceleration shaking cannot toggle it")
func drawingTiltToggle() {
    var engine = drawingEngine()
    for tick in 1...35 { engine.update(drawingSample(tick, acceleration: MotionVector(x: (tick / 5).isMultiple(of: 2) ? 1.2 : -1.2, y: 0, z: 0))) }
    #expect(!engine.isPenDown && engine.strokes.isEmpty)
    for tick in 36...70 { engine.update(drawingSample(tick)) }
    let next = drawingToggle(&engine, from: 71)
    #expect(engine.isPenDown)
    #expect(engine.strokes.count == 1 && engine.pointCount == 1)
    for tick in next..<(next + 30) { engine.update(drawingSample(tick, rotation: drawingRotation(right: 20))) }
    #expect(engine.pointCount > 1)
    drawingToggle(&engine, from: next + 30)
    #expect(!engine.isPenDown)
    let points = engine.pointCount
    for tick in (next + 90)..<(next + 120) { engine.update(drawingSample(tick, rotation: drawingRotation(forward: 20))) }
    #expect(engine.pointCount == points)
}

@Test("Repeated tilt oscillations cannot chatter or draw until the controller returns to level")
func drawingTiltDebounce() {
    var engine = drawingEngine(); var toggles = 0
    for tick in 1...35 {
        let angle: Float = (tick / 5).isMultiple(of: 2) ? -50 : 50
        if let event = engine.update(drawingSample(tick, rotation: drawingRotation(right: angle))), event == .penDown || event == .penUp { toggles += 1 }
    }
    #expect(toggles == 1 && engine.isPenDown)
    #expect(engine.pointCount <= 1)
}

@Test("Gaps, duplicate packets, disconnects, and inverted poses cannot leave ink bridges")
func drawingInterruptedInput() {
    var engine = drawingEngine()
    let next = drawingToggle(&engine, from: 1)
    for tick in next..<(next + 20) { engine.update(drawingSample(tick, rotation: drawingRotation(right: 20))) }
    let points = engine.pointCount, position = engine.position
    for _ in 0..<20 { engine.update(drawingSample(next + 19, rotation: drawingRotation(right: 20))) }
    #expect(engine.pointCount == points && engine.position == position)
    engine.update(drawingSample(next + 80, rotation: drawingRotation(right: 20)))
    #expect(!engine.isPenDown && engine.velocity == .zero && engine.pointCount == points)
    engine.suspend()
    #expect(!engine.isCalibrated && !engine.isTracking && engine.pointCount == points)
    let recalibrated = engine.calibrate(drawingSample(next + 90))
    #expect(recalibrated)
    drawingToggle(&engine, from: next + 91)
    #expect(engine.isPenDown)
    engine.update(drawingSample(next + 151, rotation: drawingRotation(right: 100)))
    #expect(!engine.isTracking && !engine.isPenDown)
}

@Test("Tool and ink changes start separate strokes; undo and clear preserve their contracts")
func drawingToolsAndDocument() {
    var engine = drawingEngine(); var tick = drawingToggle(&engine, from: 1)
    for tool in DrawingTool.allCases {
        engine.select(tool: tool)
        engine.select(ink: tool == .pencil ? .midnight : .coral)
        for _ in 0..<10 { engine.update(drawingSample(tick, rotation: drawingRotation(right: 12))); tick += 1 }
    }
    #expect(Set(engine.strokes.map(\.tool)) == Set(DrawingTool.allCases))
    #expect(engine.strokes.filter { $0.tool == .pencil }.allSatisfy { $0.ink == .midnight })
    let count = engine.strokes.count
    engine.undo()
    #expect(engine.strokes.count == count - 1 && !engine.isPenDown)
    #expect(engine.pointCount == engine.strokes.reduce(0) { $0 + $1.points.count })
    engine.clear()
    #expect(engine.strokes.isEmpty && engine.pointCount == 0)
}

@Test("Paper bounds prevent hidden overshoot and reversing tilt moves back immediately")
func drawingPaperBounds() {
    var engine = drawingEngine()
    for tick in 1...300 { engine.update(drawingSample(tick, rotation: drawingRotation(right: 70, forward: -20))) }
    #expect(engine.position.x == 982 && engine.position.y <= 732)
    engine.update(drawingSample(301, rotation: drawingRotation(right: -40)))
    #expect(engine.position.x < 982)
    engine.center()
    #expect(engine.position == DrawingEngine.paperSize / 2 && engine.speed == 0 && !engine.isPenDown)
}

@Test("Trigger angle changes how far each side must tilt")
func drawingTriggerAngle() {
    var small = DrawingTiltTrigger(), large = DrawingTiltTrigger()
    small.reset(time: 0); large.reset(time: 0)
    let smallLeft = small.update(roll: -15, time: 0.05, settings: .init(angle: 12))
    let largeLeft = large.update(roll: -15, time: 0.05, settings: .init(angle: 30))
    #expect(!smallLeft && !largeLeft)
    let smallResult = small.update(roll: 15, time: 0.15, settings: .init(angle: 12))
    let largeResult = large.update(roll: 15, time: 0.15, settings: .init(angle: 30))
    #expect(smallResult && !largeResult)
}

@Test("Trigger timing covers the whole movement from level through left to right")
func drawingTriggerTiming() {
    var fast = DrawingTiltTrigger(), relaxed = DrawingTiltTrigger(), slowLeft = DrawingTiltTrigger()
    fast.reset(time: 0); relaxed.reset(time: 0); slowLeft.reset(time: 0)
    let fastSettings = DrawingTriggerSettings(window: 0.15)
    let relaxedSettings = DrawingTriggerSettings(window: 0.6)
    let fastLeft = fast.update(roll: -22, time: 0.06, settings: fastSettings)
    let relaxedLeft = relaxed.update(roll: -22, time: 0.06, settings: relaxedSettings)
    let fastRight = fast.update(roll: 22, time: 0.3, settings: fastSettings)
    let relaxedRight = relaxed.update(roll: 22, time: 0.3, settings: relaxedSettings)
    #expect(!fastLeft && !relaxedLeft && !fastRight && relaxedRight)
    let slowStart = slowLeft.update(roll: -22, time: 0.8, settings: relaxedSettings)
    let slowFinish = slowLeft.update(roll: 22, time: 0.9, settings: relaxedSettings)
    #expect(!slowStart && !slowFinish)
}

@Test("Right-then-left, one-sided tilts, and forward tilts cannot toggle the pen")
func drawingTriggerOrderAndAxis() {
    var wrongOrder = DrawingTiltTrigger(), oneSide = DrawingTiltTrigger()
    wrongOrder.reset(time: 0); oneSide.reset(time: 0)
    let first = wrongOrder.update(roll: 25, time: 0.05, settings: .init())
    let second = wrongOrder.update(roll: -25, time: 0.15, settings: .init())
    let left = oneSide.update(roll: -25, time: 0.05, settings: .init())
    let held = oneSide.update(roll: -25, time: 0.6, settings: .init())
    #expect(!first && !second && !left && !held)
    var engine = drawingEngine()
    for tick in 1...60 { engine.update(drawingSample(tick, rotation: drawingRotation(forward: tick < 30 ? 50 : -50))) }
    #expect(!engine.isPenDown)
}

@Test("Tilt triggers are consistent at 30, 60, and 120 Hz")
func drawingTriggerSensorRates() {
    for hz in [30, 60, 120] {
        var engine = DrawingEngine(); engine.calibrate(drawingSample(0))
        var toggles = 0
        for tick in 1...hz {
            let time = Double(tick) / Double(hz)
            let roll: Float = time < 0.1 ? 0 : time < 0.2 ? -25 : time < 0.3 ? 25 : 0
            if engine.update(drawingSample(tick, hz: Double(hz), rotation: drawingRotation(right: roll))) == .penDown { toggles += 1 }
        }
        #expect(toggles == 1 && engine.isPenDown && !engine.isSettling)
    }
}

@Test("Settings changes cancel partial gestures and clamp unsafe angle or time values")
func drawingTriggerSettings() {
    var engine = DrawingEngine(); engine.calibrate(drawingSample(0))
    engine.update(drawingSample(1, rotation: drawingRotation(right: -25)))
    #expect(engine.triggerPhase == .waitingForRight)
    engine.configureTrigger(.init(angle: 10, window: 0.7))
    engine.update(drawingSample(7, rotation: drawingRotation(right: 25)))
    #expect(!engine.isPenDown && engine.triggerPhase == .returnToLevel)
    for tick in 8...30 { engine.update(drawingSample(tick)) }
    #expect(engine.triggerPhase == .ready)
    drawingToggle(&engine, from: 31)
    #expect(engine.isPenDown)
    engine.suspend()
    #expect(engine.triggerSettings == DrawingTriggerSettings(angle: 10, window: 0.7))
    #expect(DrawingTriggerSettings(angle: .nan, window: .infinity).bounded == DrawingTriggerSettings())
    #expect(DrawingTriggerSettings(angle: -20, window: 0).bounded == DrawingTriggerSettings(angle: 8, window: 0.15))
    #expect(DrawingTriggerSettings(angle: 100, window: 10).bounded == DrawingTriggerSettings(angle: 45, window: 1))
}
