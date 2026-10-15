import Foundation
import simd

struct FlightRing: Sendable, Identifiable {
    let id: Int
    let center: SIMD3<Float>
    var radius: Float = 4.8
}
struct FlightObstacle: Sendable, Identifiable {
    let id: Int
    let center: SIMD3<Float>
    var radius: Float = 2.6
}
struct PaperFlightCourse: Sendable {
    let rings: [FlightRing] = [
        .init(id: 0, center: [0, 8, -35]), .init(id: 1, center: [-6, 10, -75]),
        .init(id: 2, center: [4, 13, -115]), .init(id: 3, center: [10, 9, -155]),
        .init(id: 4, center: [-3, 7, -200]), .init(id: 5, center: [-10, 11, -245]),
        .init(id: 6, center: [3, 13, -290]), .init(id: 7, center: [0, 10, -335])
    ]
    let obstacles: [FlightObstacle] = [
        .init(id: 0, center: [6, 8, -54]), .init(id: 1, center: [-10, 11, -95]),
        .init(id: 2, center: [0, 17, -135]), .init(id: 3, center: [11, 5, -178]),
        .init(id: 4, center: [7, 7, -222]), .init(id: 5, center: [8, 11, -267]),
        .init(id: 6, center: [-9, 12, -313])
    ]
    let windCenters: [SIMD3<Float>] = [[-2, 9, -55], [6, 11, -140], [-6, 11, -255]]
}

enum FlightPhase: Sendable { case ready, countdown, flying, crashed, finished }
enum FlightRingResult: Sendable { case ahead, passed, perfect, missed }
enum FlightCrash: String, Sendable { case ground = "Too close to the water", storm = "Caught a storm cloud", ring = "Clipped a ring", lost = "Carried off course" }
enum FlightEvent: Sendable, Equatable {
    case calibrated, launched, boost, turbulence, ringPassed(Int, perfect: Bool), ringMissed(Int), crashed(FlightCrash), finished
}

struct PaperFlightEngine: Sendable {
    // Conservative envelope includes the nose and both wing tips of the rendered model.
    static let bodyRadius: Float = 1.5
    let course = PaperFlightCourse()
    private(set) var flightID = UUID()
    private(set) var phase = FlightPhase.ready
    private(set) var position = SIMD3<Float>(0, 8, 0)
    private(set) var bank: Float = 0
    private(set) var pitch: Float = 0
    private(set) var heading: Float = 0
    private(set) var speed: Float = 9
    private(set) var elapsed = 0.0
    private(set) var phaseAge = 0.0
    private(set) var countdown = 3.0
    private(set) var countdownNumber = 3
    private(set) var boostRemaining = 0.0
    private(set) var boostCount = 0
    private(set) var inTurbulence = false
    private(set) var results = Array(repeating: FlightRingResult.ahead, count: 8)
    private(set) var score = 0
    private(set) var crashReason: FlightCrash?
    private(set) var tiltDegrees = SIMD2<Float>.zero
    private(set) var isTracking = false
    private(set) var calibrationProgress = 0.0
    private(set) var neutralProgress = 0.0
    var sensitivity: Float = 1
    var isCalibrated: Bool { pose != nil }
    var ringsPassed: Int { results.filter { $0 == .passed || $0 == .perfect }.count }
    var perfectPasses: Int { results.filter { $0 == .perfect }.count }
    var nextRing: Int { results.firstIndex(of: .ahead) ?? course.rings.count }
    var orientation: MotionQuaternion {
        MotionQuaternion(simd_quatf(angle: -heading, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: -bank, axis: [0, 0, 1]))
    }
    var forward: SIMD3<Float> { [sin(heading) * cos(pitch), sin(pitch), -cos(heading) * cos(pitch)] }
    private var pose: TiltPose?
    private var previousTime: Double?
    private var previousSequence: UInt64?
    private var boostArmed = true
    private var quietBoostTime = 0.0
    private var boostReadyAt = 0.0

    mutating func reset() {
        let oldPose = pose, time = previousTime, sequence = previousSequence, gain = sensitivity
        self = Self(); pose = oldPose; previousTime = time; previousSequence = sequence; sensitivity = gain
        isTracking = oldPose != nil
    }
    @discardableResult mutating func launch() -> Bool {
        guard isCalibrated else { return false }
        reset(); phase = .countdown
        return true
    }
    mutating func suspend() {
        pose = nil; previousTime = nil; previousSequence = nil; neutralProgress = 0
        isTracking = false; calibrationProgress = 0; boostArmed = false; quietBoostTime = 0
        if phase == .countdown { phase = .ready; countdown = 3; countdownNumber = 3 }
    }
    @discardableResult mutating func calibrate(_ sample: MotionSample) -> Bool {
        guard TiltPose.canCapture(sample) else { return false }
        pose = TiltPose(sample); previousTime = sample.timestamp; previousSequence = sample.sequence
        tiltDegrees = .zero; neutralProgress = 0; calibrationProgress = 1; isTracking = true
        boostArmed = false; quietBoostTime = 0
        if phase == .countdown { countdown = 3; countdownNumber = 3 }
        return true
    }
    @discardableResult mutating func update(_ sample: MotionSample) -> [FlightEvent] {
        guard sample.isValid else { suspend(); return [] }
        if let previousSequence, sample.sequence <= previousSequence { return [] }
        let dt = previousTime.map { sample.timestamp - $0 } ?? 0
        previousTime = sample.timestamp; previousSequence = sample.sequence
        guard dt > 0 && dt <= 0.2 else {
            neutralProgress = 0; quietBoostTime = 0
            if phase == .countdown { countdown = 3; countdownNumber = 3 }
            return []
        }
        guard let pose else {
            let steady = TiltPose.canCapture(sample) && sample.gravity.z < -0.35 && sample.rotationRate.magnitude < 0.4
                && sample.acceleration.magnitude < 0.12
            calibrationProgress = steady ? min(1, calibrationProgress + dt / 0.7) : 0
            if calibrationProgress >= 1 && calibrate(sample) { return [.calibrated] }
            return []
        }
        phaseAge += dt
        let gravity = pose.gravity(sample)
        tiltDegrees = TiltPose.angles(gravity); isTracking = gravity.z < -0.087
        guard phase != .crashed && phase != .finished else { return [] }
        guard isTracking else {
            neutralProgress = 0
            if phase == .countdown { countdown = 3; countdownNumber = 3 }
            return []
        }
        let steady = simd_length(tiltDegrees) < 8 && sample.acceleration.magnitude < 0.18 && sample.rotationRate.magnitude < 0.65
        if phase == .countdown {
            countdown = steady ? max(0, countdown - dt) : 3
            countdownNumber = max(1, Int(ceil(countdown)))
            if countdown <= 0 { phase = .flying; phaseAge = 0; neutralProgress = 1; boostArmed = true; return [.launched] }
            return []
        }
        if neutralProgress < 1 {
            neutralProgress = steady ? min(1, neutralProgress + dt / 0.25) : 0
            return []
        }
        guard phase == .flying else { return [] }
        let relative = sample.attitude.relative(to: pose.reference).rotation
        let acceleration = pose.controlToDevice.rotation.inverse.act(relative.act(sample.acceleration.simdValue))
        if abs(acceleration.y) < 0.2 && sample.rotationRate.magnitude < 1 { quietBoostTime += dt }
        else { quietBoostTime = 0 }
        if quietBoostTime > 0.18 && elapsed >= boostReadyAt { boostArmed = true }
        var events: [FlightEvent] = []
        if acceleration.y > 0.65 && boostArmed && elapsed >= boostReadyAt {
            boostArmed = false; boostRemaining = 1.6; boostReadyAt = elapsed + 2.5; boostCount += 1
            events.append(.boost)
        }
        let gain = sensitivity.isFinite ? min(1.5, max(0.5, sensitivity)) : 1
        let targetBank = min(0.95, max(-0.95, tiltDegrees.x * .pi / 180 * gain))
        let targetPitch = min(0.5, max(-0.5, -tiltDegrees.y * .pi / 180 * gain))
        let steps = max(1, Int(ceil(dt * 120)))
        for _ in 0..<steps {
            guard phase == .flying else { break }
            let h = Float(dt / Double(steps)), previous = position
            elapsed += Double(h); boostRemaining = max(0, boostRemaining - Double(h))
            bank += (targetBank - bank) * (1 - exp(-6 * h)); pitch += (targetPitch - pitch) * (1 - exp(-5 * h))
            let targetSpeed: Float = 9 - 1.5 * sin(pitch) + (boostRemaining > 0 ? 6 : 0)
            speed += (targetSpeed - speed) * (1 - exp(-1.8 * h))
            let turnRate = min(0.7, max(-0.7, 9.81 * tan(bank) / max(6, speed) * 0.55))
            heading += turnRate * h
            let turbulent = course.windCenters.contains { simd_distance($0, position) < 7 }
            if turbulent && !inTurbulence { events.append(.turbulence) }
            inTurbulence = turbulent
            let wind: SIMD3<Float> = turbulent ? [sin(Float(elapsed) * 4) * 0.35, sin(Float(elapsed) * 2.7) * 0.18, 0] : .zero
            position += (forward * speed + wind) * h
            events += checkSegment(from: previous, to: position)
            if elapsed >= 180 && phase == .flying { events.append(crash(.lost)) }
        }
        return events
    }

    /// Resolve rings, storm spheres, and the water over the entire swept flight segment.
    @discardableResult mutating func checkSegment(from start: SIMD3<Float>, to end: SIMD3<Float>) -> [FlightEvent] {
        guard phase == .flying else { return [] }
        position = end
        var impact: (Float, FlightCrash)?
        func contact(_ t: Float, _ reason: FlightCrash) { if impact == nil || t < impact!.0 { impact = (t, reason) } }
        if end.y <= Self.bodyRadius {
            contact(start.y <= Self.bodyRadius ? 0 : (start.y - Self.bodyRadius) / max(0.00001, start.y - end.y), .ground)
        }
        for obstacle in course.obstacles {
            if let t = Self.sphereContact(from: start, to: end, center: obstacle.center, radius: obstacle.radius + Self.bodyRadius) { contact(t, .storm) }
        }
        for ring in course.rings {
            if let t = Self.ringContact(from: start, to: end, ring: ring) { contact(t, .ring) }
        }
        var crossings: [(Float, Int, Float)] = []
        if end.z < start.z {
            for ring in course.rings where results[ring.id] == .ahead && start.z > ring.center.z && end.z <= ring.center.z {
                let t = (start.z - ring.center.z) / (start.z - end.z)
                let point = start + (end - start) * t
                let offset = simd_length(SIMD2(point.x - ring.center.x, point.y - ring.center.y))
                crossings.append((t, ring.id, offset))
            }
        }
        var events: [FlightEvent] = []
        for (t, index, distance) in crossings.sorted(by: { $0.0 < $1.0 }) {
            if let impact, impact.0 <= t { break }
            let perfect = distance < course.rings[index].radius * 0.3
            if distance < course.rings[index].radius - Self.bodyRadius {
                results[index] = perfect ? .perfect : .passed; score += perfect ? 150 : 100
                events.append(.ringPassed(index, perfect: perfect))
            } else { results[index] = .missed; events.append(.ringMissed(index)) }
            if index == course.rings.count - 1 {
                position = start + (end - start) * t; phase = .finished; phaseAge = 0
                events.append(.finished); return events
            }
        }
        if let impact { position = start + (end - start) * max(0, min(1, impact.0)); events.append(crash(impact.1)) }
        else if abs(position.x) > 70 || position.y > 55 || position.z > 35 { events.append(crash(.lost)) }
        return events
    }
    private mutating func crash(_ reason: FlightCrash) -> FlightEvent {
        phase = .crashed; phaseAge = 0; crashReason = reason; boostRemaining = 0
        return .crashed(reason)
    }
    static func sphereContact(from start: SIMD3<Float>, to end: SIMD3<Float>, center: SIMD3<Float>, radius: Float) -> Float? {
        let delta = end - start, offset = start - center
        let c = simd_dot(offset, offset) - radius * radius
        if c <= 0 { return 0 }
        let a = simd_dot(delta, delta), b = 2 * simd_dot(offset, delta)
        guard a > 0.000001 else { return nil }
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }
        let t = (-b - sqrt(discriminant)) / (2 * a)
        return (0...1).contains(t) ? t : nil
    }
    /// Sphere tracing the torus distance field catches rim grazes before crossing the ring plane,
    /// including sideways motion. A distance-field step cannot skip a solid surface.
    static func ringContact(from start: SIMD3<Float>, to end: SIMD3<Float>, ring: FlightRing) -> Float? {
        let padding = bodyRadius + 0.15
        if min(start.z, end.z) > ring.center.z + padding || max(start.z, end.z) < ring.center.z - padding { return nil }
        let delta = end - start, length = simd_length(delta)
        var t: Float = 0
        for _ in 0..<96 {
            let p = start + delta * t - ring.center
            let radial = simd_length(SIMD2(p.x, p.y)) - ring.radius
            let distance = sqrt(radial * radial + p.z * p.z) - padding
            if distance <= 0.0005 { return t }
            guard length > 0.00001 else { return nil }
            t += distance / length
            if t > 1 { return nil }
        }
        return nil
    }
}

/// Drives the same engine with synthetic controller samples; never connects to haptics or scores.
struct PaperFlightPreview: Sendable {
    private(set) var engine = PaperFlightEngine()
    private(set) var frame: UInt64 = 0
    init(sensitivity: Float = 1) {
        engine.sensitivity = sensitivity.isFinite ? min(1.5, max(0.5, sensitivity)) : 1
        engine.calibrate(Self.sample(frame: 0)); engine.launch()
    }
    mutating func tick() {
        frame &+= 1
        var rotation = MotionQuaternion.identity
        var acceleration = SIMD3<Float>.zero
        if engine.phase == .flying {
            let target = engine.course.rings[min(engine.nextRing, engine.course.rings.count - 1)].center
            let delta = target - engine.position
            let desiredHeading = atan2(delta.x, -delta.z)
            let difference = atan2(sin(desiredHeading - engine.heading), cos(desiredHeading - engine.heading))
            let rate = max(-0.55, min(0.55, difference * 1.8))
            let bank = max(-0.7, min(0.7, atan(rate * engine.speed / (9.81 * 0.55))))
            let pitch = max(-0.35, min(0.35, atan2(delta.y * 1.5, max(8, -delta.z))))
            let gravity = simd_normalize(SIMD3<Float>(tan(bank / engine.sensitivity), tan(-pitch / engine.sensitivity), -1))
            rotation = MotionQuaternion(simd_quatf(from: gravity, to: SIMD3<Float>(0, 0, -1)))
            if engine.elapsed > 5 && engine.boostCount == 0 { acceleration = rotation.rotation.inverse.act([0, 0.9, 0]) }
        }
        engine.update(Self.sample(frame: frame, rotation: rotation, acceleration: acceleration))
    }
    private static func sample(frame: UInt64, rotation: MotionQuaternion = .identity, acceleration: SIMD3<Float> = .zero) -> MotionSample {
        MotionSample(sequence: frame, timestamp: Double(frame) / 60, attitude: rotation,
                     rotationRate: .zero, acceleration: MotionVector(acceleration), gravity: MotionVector(x: 0, y: 0, z: -1))
    }
}
