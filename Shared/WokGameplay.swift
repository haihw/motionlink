import Foundation
import simd

enum EggDoneness: String, CaseIterable, Identifiable, Sendable {
    case soft = "Soft", medium = "Medium", firm = "Firm"
    var id: Self { self }
    var target: ClosedRange<Double> {
        switch self { case .soft: 0.18...0.34; case .medium: 0.36...0.54; case .firm: 0.60...0.78 }
    }
    var description: String {
        switch self { case .soft: "Tender white · runny yolk"; case .medium: "Golden white · jammy yolk"; case .firm: "Crisp white · firm yolk" }
    }
}

enum WokPhase: Sendable { case ready, cracking, cooking, airborne, served, lost, burnt }

struct WokInput: Sendable {
    var rotation = MotionQuaternion.identity
    var translation = SIMD3<Float>.zero
    var velocity = SIMD3<Float>.zero
    var acceleration = SIMD3<Float>.zero
    var gyro = SIMD3<Float>.zero
    var sampleID: UInt64 = 0
    var active = true
    var recenterID: UInt64 = 0
    static func autoplay(engine: WokGameEngine, sampleID: UInt64) -> Self {
        let cycle = max(0, engine.elapsed - 1.1).truncatingRemainder(dividingBy: 9)
        let practiceToss = engine.practiceMode && engine.phase == .cooking && cycle >= 6.5 && cycle < 6.8
        let toss = practiceToss || (!engine.practiceMode && engine.phase == .cooking && engine.flips == 0 && engine.sear[0] >= 0.61)
        let doubleSpin = practiceToss && Int(max(0, engine.elapsed - 1.1) / 9).isMultiple(of: 2) == false
        let t = Float(max(0, engine.elapsed - 1.1))
        let movingTime = engine.practiceMode ? Float(cycle) : t
        let radius: Float = 0.12 * min(1, movingTime) * (engine.practiceMode ? min(1, max(0, 6.5 - movingTime)) : min(1, max(0, 9 - Float(engine.elapsed))))
        let position: SIMD3<Float> = engine.phase == .cooking && (engine.practiceMode || engine.flips == 0) && !toss
            ? [radius * sin(t * 2.8), 0, radius * (1 - cos(t * 2.8))] : .zero
        return Self(translation: position,
                    acceleration: toss ? [0, doubleSpin ? 14 : 7, doubleSpin ? -8 : -4] : .zero, gyro: toss ? [doubleSpin ? 4.5 : 1, 0, 0] : .zero, sampleID: sampleID)
    }
}

/// A game simulation: contact sears each face; gravity and the moving pan govern tosses.
/// These normalized cooking levels are gameplay values, not food-safety measurements.
struct WokGameEngine: Sendable {
    static let radius: Float = 1.05
    static let eggRadius: Float = 0.25
    static let gravity: Float = 9.81
    private(set) var phase = WokPhase.ready
    private(set) var target = EggDoneness.medium
    private(set) var elapsed = 0.0
    private(set) var phaseTime = 0.0
    private(set) var sear = [0.0, 0.0]
    private(set) var contactSide = 0
    private(set) var flips = 0
    private(set) var perfectFlips = 0
    private(set) var attempts = 0
    private(set) var practiceMode = false
    private(set) var lastFlipTurns = 0
    private(set) var totalTurns = 0
    private(set) var feedback = "Ready for the first egg?"
    private(set) var rating = 0
    private(set) var eggPosition = SIMD3<Float>(0, 1.5, 0)
    private(set) var eggRotation = MotionQuaternion.identity
    private(set) var panPosition = SIMD3<Float>.zero
    private(set) var panRotation = MotionQuaternion.identity
    private var eggFaceRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
    private var eggVelocity = SIMD3<Float>.zero
    private var panVelocity = SIMD3<Float>.zero
    private var panAngularVelocity = SIMD3<Float>.zero
    static let bowlCurvature: Float = 0.39 / (radius * radius)
    static let staticFriction: Float = 0.06
    static let kineticFriction: Float = 0.045
    private var localEgg = SIMD3<Float>.zero
    private var flightStartPosition = SIMD3<Float>.zero
    private var flightStartLocalRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
    private var flightAxis = SIMD3<Float>(1, 0, 0)
    private var flightSign: Float = 1
    private var flightDuration: Float = 0.8
    private var flightInitialSide = 0
    private var goodTiming = false
    private var lastRecenter: UInt64 = 0
    private var flickDetector = WokFlickDetector()

    var finished: Bool { phase == .served || phase == .lost || phase == .burnt }
    var flipWindow: Bool { contactSide == 0 && (0.50...0.72).contains(sear[0]) }
    var readyToServe: Bool { flips > 0 && sear[0] >= 0.5 && sear[0] < 0.98 && target.target.contains(sear[1]) }
    var cookingProgress: Double { min(1, sear[1] / target.target.upperBound) }
    var phaseLabel: String {
        switch phase {
        case .ready: "Ready to cook"; case .cracking: "Cracking the egg"; case .airborne: lastFlipTurns == 2 ? "2 spins + flip" : "1 spin + flip"
        case .cooking: practiceMode ? "Your phone is the wok" : readyToServe ? "Serve now" : flipWindow ? "Flip now!" : contactSide == 0 ? "Sear the first side" : "Finish the second side"
        case .served: rating == 3 ? "Chef’s kiss." : "Egg served"
        case .lost: "Egg overboard"; case .burnt: "Too much heat"
        }
    }
    static func surfaceHeight(_ position: SIMD3<Float>) -> Float {
        0.06 + bowlCurvature * (position.x * position.x + position.z * position.z)
    }

    mutating func start(target: EggDoneness, practice: Bool = false) {
        self = Self(); self.target = target; practiceMode = practice; phase = .cracking
        if practice { sear = [0.55, 0.2] }
        feedback = practice ? "Free play — circle, tilt, and flick. Heat is off." : "Fresh egg. Let the white set before tossing."
    }

    mutating func step(deltaTime: Double, input: WokInput) {
        guard input.active, input.rotation.isValid, input.translation.x.isFinite,
              input.translation.y.isFinite, input.translation.z.isFinite,
              deltaTime.isFinite, deltaTime > 0, deltaTime <= 0.1,
              phase != .ready, phase != .served, phase != .burnt else { return }
        if input.recenterID != lastRecenter {
            lastRecenter = input.recenterID
            if phase == .cooking || phase == .cracking { eggPosition += input.translation - panPosition }
            panPosition = input.translation; eggVelocity = .zero
        }
        let previousPosition = panPosition, previousRotation = panRotation.rotation
        let nextRotation = input.rotation.rotation
        panVelocity = (input.translation - previousPosition) / Float(deltaTime)
        var delta = nextRotation * previousRotation.inverse
        if delta.real < 0 { delta = simd_quatf(vector: -delta.vector) }
        let angle = 2 * atan2(simd_length(delta.imag), max(0, delta.real))
        panAngularVelocity = simd_length(delta.imag) > 0.000001 ? simd_normalize(delta.imag) * angle / Float(deltaTime) : .zero
        elapsed += deltaTime; phaseTime += deltaTime
        if let flick = flickDetector.update(input, time: elapsed), phase == .cooking { launch(flick) }
        let substeps = max(1, Int(ceil(deltaTime * 240)))
        for index in 0..<substeps {
            let fraction = Float(index + 1) / Float(substeps)
            panPosition = previousPosition + (input.translation - previousPosition) * fraction
            panRotation = MotionQuaternion(simd_slerp(previousRotation, nextRotation, fraction))
            advance(Float(deltaTime) / Float(substeps))
        }
    }

    private mutating func launch(_ flick: WokFlick) {
        goodTiming = flipWindow && !practiceMode
        attempts += 1; lastFlipTurns = flick.spins
        phase = .airborne; phaseTime = 0
        flightStartPosition = eggPosition
        flightStartLocalRotation = panRotation.rotation.inverse * eggRotation.rotation
        flightAxis = flick.axis
        flightSign = flick.sign
        flightDuration = flick.spins == 2 ? 0.95 : 0.75
        flightInitialSide = contactSide
        feedback = flick.spins == 2 ? "Double spin + flip!" : "Single spin + flip!"
    }

    private mutating func advance(_ dt: Float) {
        let q = panRotation.rotation
        if phase == .cracking {
            let fraction = Float(min(1, phaseTime / 1.1))
            localEgg = [0, Self.surfaceHeight(.zero) + 1.5 * (1 - fraction * fraction), 0]
            eggPosition = panPosition + q.act(localEgg)
            eggRotation = panRotation
            if fraction >= 1 { phase = .cooking; phaseTime = 0 }
        } else if phase == .cooking {
            if q.act(SIMD3<Float>(0, 1, 0)).y < -0.05 {
                phase = .lost; phaseTime = 0; feedback = "The wok is upside down. Face the screen up to keep the egg inside."; return
            }
            // Integrate the egg in the inertial world frame. A level translating
            // pan cannot carry the egg sideways unless contact friction transfers momentum.
            eggVelocity.y -= Self.gravity * dt
            eggPosition += eggVelocity * dt
            localEgg = q.inverse.act(eggPosition - panPosition)
            let radialDistance = simd_length(SIMD2(localEgg.x, localEgg.z))
            if radialDistance > Self.radius - Self.eggRadius {
                let radial = SIMD3<Float>(localEgg.x, 0, localEgg.z) / radialDistance
                if q.act(SIMD3<Float>(0, 1, 0)).y < 0.45 {
                    phase = .lost; phaseTime = 0; feedback = "The wok tipped too far. Keep the egg inside the rim."; return
                }
                localEgg.x = radial.x * (Self.radius - Self.eggRadius)
                localEgg.z = radial.z * (Self.radius - Self.eggRadius)
                let wallNormal = q.act(radial)
                let surfaceVelocity = panVelocity + simd_cross(panAngularVelocity, q.act(localEgg))
                let outward = simd_dot(eggVelocity - surfaceVelocity, wallNormal)
                if outward > 0 { eggVelocity -= wallNormal * outward * 1.2 }
            }
            localEgg.y = Self.surfaceHeight(localEgg)
            let localNormal = simd_normalize(SIMD3<Float>(-2 * Self.bowlCurvature * localEgg.x, 1,
                                                         -2 * Self.bowlCurvature * localEgg.z))
            let normal = q.act(localNormal)
            let contact = q.act(localEgg)
            let surfaceVelocity = panVelocity + simd_cross(panAngularVelocity, contact)
            var relativeVelocity = eggVelocity - surfaceVelocity
            let normalSpeed = simd_dot(relativeVelocity, normal)
            let normalImpulse = max(0, -normalSpeed)
            // Constraint impulse supports gravity and supplies curvature acceleration.
            eggVelocity -= normal * normalSpeed
            relativeVelocity -= normal * normalSpeed
            let tangentSpeed = simd_length(relativeVelocity)
            if tangentSpeed <= Self.staticFriction * normalImpulse {
                eggVelocity -= relativeVelocity
            } else if tangentSpeed > 0.000001 {
                let frictionImpulse = min(tangentSpeed, Self.kineticFriction * normalImpulse)
                eggVelocity -= relativeVelocity / tangentSpeed * frictionImpulse
            }
            eggPosition = panPosition + contact
            // The egg lies along the bowl surface rather than hovering level above its slope.
            let surfaceRotation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: localNormal)
            eggRotation = MotionQuaternion(q * surfaceRotation * eggFaceRotation)
            let heat = Double(max(0.1, q.act(SIMD3<Float>(0, 1, 0)).y))
                * Double(max(0.2, 1 - max(0, panPosition.y) * 0.8))
            if !practiceMode { sear[contactSide] += Double(dt) * 0.05 * heat }
            if sear[contactSide] >= 1 {
                phase = .burnt; feedback = "The egg burned. Flip earlier and serve inside the target band."
            }
        } else if phase == .airborne {
            // Deliberate game assist: the flick chooses the spin count and a
            // controlled arc follows the moving bowl, returning to the opposite face.
            let progress = min(1, Float(phaseTime) / flightDuration)
            let blend = progress * progress * (3 - 2 * progress)
            let target = panPosition + q.act(SIMD3<Float>(0, Self.surfaceHeight(.zero), 0))
            let base = flightStartPosition + (target - flightStartPosition) * blend
            let t = progress * flightDuration
            eggPosition = base + SIMD3<Float>(0, Self.gravity * 0.5 * t * (flightDuration - t), 0)
            let flatStart = eggFaceRotation
            let localBase = simd_slerp(flightStartLocalRotation, flatStart, blend)
            let spinAngle = flightSign * Float(lastFlipTurns * 2 + 1) * .pi * progress
            eggRotation = MotionQuaternion(q * simd_quatf(angle: spinAngle, axis: flightAxis) * localBase)
            if progress >= 1 {
                contactSide = 1 - flightInitialSide
                flips += 1; totalTurns += lastFlipTurns
                if goodTiming { perfectFlips += 1 }
                feedback = practiceMode ? "Nice flip! Try circling, tilting, or a faster flick."
                    : goodTiming ? "Perfect flip! Finish the other side." : sear[flightInitialSide] < 0.50 ? "Early flip — turn it back to finish searing that side." : "Nice flip! Watch the cooking target."
                localEgg = [0, Self.surfaceHeight(.zero), 0]
                eggPosition = target
                eggFaceRotation = simd_quatf(angle: flightSign * Float(lastFlipTurns * 2 + 1) * .pi, axis: flightAxis) * flatStart
                eggRotation = MotionQuaternion(q * eggFaceRotation)
                eggVelocity = panVelocity + simd_cross(panAngularVelocity, q.act(localEgg))
                phase = .cooking; phaseTime = 0
            }
        } else if phase == .lost {
            eggVelocity.y -= Self.gravity * dt
            eggPosition += eggVelocity * dt
            if eggPosition.y < -0.5 {
                eggPosition.y = -0.5
                eggVelocity.y = max(0, -eggVelocity.y * 0.15)
                eggVelocity.x *= 0.97; eggVelocity.z *= 0.97
            }
        }
    }

    mutating func serve() {
        guard phase == .cooking && !practiceMode else { return }
        rating = readyToServe ? (perfectFlips > 0 ? 3 : 2) : 1
        feedback = readyToServe ? "\(target.rawValue) egg, right on target." : sear[1] < target.target.lowerBound ? "Served too early for \(target.rawValue.lowercased()) doneness." : "Past the target — serve a little sooner."
        phase = .served
    }
}

/// Align the captured phone pose with gravity, so a horizontal phone circle remains
/// horizontal in the kitchen even when setup begins with the phone lying flat.
struct WokMotionFrame: Sendable {
    let deviceToKitchen: MotionQuaternion
    init(gravity: MotionVector) {
        let rawUp = -gravity.simdValue
        let up = simd_length(rawUp) > 0.5 ? simd_normalize(rawUp) : SIMD3<Float>(0, 1, 0)
        var forward = SIMD3<Float>(0, 1, 0) - up * simd_dot([0, 1, 0], up)
        if simd_length(forward) < 0.1 { forward = SIMD3<Float>(0, 0, -1) - up * simd_dot([0, 0, -1], up) }
        forward = simd_normalize(forward)
        let right = simd_normalize(simd_cross(forward, up))
        deviceToKitchen = MotionQuaternion(simd_quatf(simd_float3x3(columns: (right, up, -forward))).inverse)
    }
    func deviceRotation(_ relative: MotionQuaternion) -> MotionQuaternion {
        MotionQuaternion(deviceToKitchen.rotation * relative.rotation)
    }
    func wokRotation(_ relative: MotionQuaternion) -> MotionQuaternion {
        // Phone screen normal (+Z) is the wok opening (+Y). Position/heading
        // calibration preserves the phone's actual inclination to gravity.
        let phoneFromWok = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        return MotionQuaternion(deviceToKitchen.rotation * relative.rotation * phoneFromWok)
    }
}

/// Integrates estimated velocity once on the sensor clock. The wok has no remote
/// pivot or amplification: one estimated metre moves the whole bowl one metre.
struct WokTranslationTracker: Sendable {
    private(set) var displacement = SIMD3<Float>.zero
    private var lastTimestamp: Double?
    private var previousVelocity = SIMD3<Float>.zero
    mutating func reset() { self = Self() }
    mutating func update(_ estimate: MotionEstimate, timestamp: Double) -> SIMD3<Float> {
        guard estimate.isAvailable, estimate.velocity.isValid, timestamp.isFinite else { reset(); return displacement }
        let velocity = estimate.speed >= 0.02 ? estimate.velocity.simdValue : .zero
        guard let lastTimestamp else {
            self.lastTimestamp = timestamp; previousVelocity = velocity; return displacement
        }
        let dt = timestamp - lastTimestamp
        guard dt > 0, dt <= 0.2 else { reset(); self.lastTimestamp = timestamp; return displacement }
        self.lastTimestamp = timestamp
        displacement += (previousVelocity + velocity) * Float(dt * 0.5)
        let limits = SIMD3<Float>(0.8, 0.4, 0.8)
        for axis in 0..<3 { displacement[axis] = min(limits[axis], max(-limits[axis], displacement[axis])) }
        previousVelocity = velocity
        return displacement
    }
}

struct WokFlick: Sendable {
    let spins: Int
    let axis: SIMD3<Float>
    let sign: Float
}

/// Collect a brief peak rather than classifying at the first threshold crossing.
/// Low/steady input rearms the gesture; constant acceleration can't keep tossing.
struct WokFlickDetector: Sendable {
    static let captureDuration = 0.08
    private var pendingSince: Double?
    private var forwardSince: Double?
    private var peakForward: Float = 0
    private var peakLift: Float = 0
    private var peakAngular: Float = 0
    private var axis = SIMD3<Float>(1, 0, 0)
    private var sign: Float = 1
    private var lastSample: UInt64?
    private var armed = true
    private var lastEmission = -10.0
    mutating func reset() { self = Self() }

    mutating func update(_ input: WokInput, time: Double) -> WokFlick? {
        guard input.active, time.isFinite,
              (0..<3).allSatisfy({ input.acceleration[$0].isFinite && input.gyro[$0].isFinite }) else {
            reset(); return nil
        }
        let angular = simd_length(SIMD2<Float>(input.gyro.x, input.gyro.z))
        if lastSample != input.sampleID {
            lastSample = input.sampleID
            if pendingSince == nil {
                if input.acceleration.y < 1.5 && angular < 0.4 && -input.acceleration.z < 1.5 {
                    armed = true
                }
                if let forwardSince, time - forwardSince > 0.30 { self.forwardSince = nil; peakForward = 0 }
                let forward = -input.acceleration.z
                if armed && time - lastEmission > 0.65 && (forward > 2 || -input.velocity.z > 0.15) {
                    if forwardSince == nil { forwardSince = time }
                    peakForward = max(peakForward, forward)
                }
                if armed && time - lastEmission > 0.65 && forwardSince != nil && input.acceleration.y > 3.5 {
                    pendingSince = time; peakLift = 0; peakAngular = 0; armed = false
                }
            }
            if pendingSince != nil {
                peakLift = max(peakLift, input.acceleration.y)
                peakForward = max(peakForward, -input.acceleration.z)
                if angular >= peakAngular {
                    peakAngular = angular
                    let xDominant = abs(input.gyro.x) >= abs(input.gyro.z)
                    axis = xDominant ? [1, 0, 0] : [0, 0, 1]
                    let component = xDominant ? input.gyro.x : input.gyro.z
                    sign = component >= 0 ? 1 : -1
                }
            }
        }
        guard let pendingSince, time - pendingSince >= Self.captureDuration else { return nil }
        self.pendingSince = nil; forwardSince = nil; lastEmission = time
        return WokFlick(spins: peakAngular >= 3.5 || peakLift >= 12 || peakForward >= 9 ? 2 : 1, axis: axis, sign: sign)
    }
}
