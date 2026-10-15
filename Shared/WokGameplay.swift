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

enum WokPhase: Sendable { case ready, cracking, cooking, airborne, serving, served, lost, burnt }

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
        let serveToss = engine.phase == .cooking && engine.readyToServe
        let toss = serveToss || practiceToss || (!engine.practiceMode && engine.phase == .cooking && engine.flips == 0 && engine.sear[0] >= 0.61)
        let doubleSpin = serveToss || (practiceToss && Int(max(0, engine.elapsed - 1.1) / 9).isMultiple(of: 2) == false)
        let t = Float(max(0, engine.elapsed - 1.1))
        let movingTime = engine.practiceMode ? Float(cycle) : t
        let radius: Float = 0.10 * min(1, movingTime) * (engine.practiceMode ? min(1, max(0, 6.5 - movingTime)) : min(1, max(0, 9 - Float(engine.elapsed))))
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
    static let platePosition = SIMD3<Float>(1.55, -0.49, 0.45)
    static let plateCatchPosition = platePosition + SIMD3<Float>(0, 0.028, 0)
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
    private(set) var servingDestination = Self.plateCatchPosition
    private(set) var heatingMultiplier = 0.0
    private var restingDuration = 0.0
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
    private var servingStartRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
    private var flightAxis = SIMD3<Float>(1, 0, 0)
    private var flightSign: Float = 1
    private var flightDuration: Float = 0.8
    private var flightInitialSide = 0
    private var goodTiming = false
    private var lastRecenter: UInt64 = 0
    private var flickDetector = WokFlickDetector()

    var finished: Bool { phase == .served || phase == .lost || phase == .burnt }
    var flipWindow: Bool { contactSide == 0 && firstSideTarget.contains(sear[0]) }
    var firstSideMinimum: Double { max(0.5, target.target.lowerBound) }
    var firstSideTarget: ClosedRange<Double> { firstSideMinimum...0.72 }
    var readyToServe: Bool {
        !practiceMode && flips > 0 && sear[0] >= firstSideMinimum
            && sear[1] >= target.target.lowerBound && sear.allSatisfy { $0 < 1 }
    }
    var cookingProgress: Double { min(1, sear[1] / target.target.upperBound) }
    var phaseLabel: String {
        switch phase {
        case .ready: "Ready to cook"; case .cracking: "Cracking the egg"; case .airborne: lastFlipTurns == 2 ? "2 spins + flip" : "1 spin + flip"
        case .serving: "Plate catch!"
        case .cooking: practiceMode ? "Your phone is the wok" : readyToServe ? "Big toss to serve!" : flipWindow ? "Flip now!"
                : contactSide == 1 && sear[1] >= target.target.lowerBound && sear[0] < firstSideMinimum ? "Flip back to finish the first side"
                : contactSide == 0 ? "Sear the first side" : "Finish the second side"
        case .served: rating == 3 ? "Chef’s kiss." : "Egg served"
        case .lost: "Egg overboard"; case .burnt: "Too much heat"
        }
    }
    static func surfaceHeight(_ position: SIMD3<Float>) -> Float {
        0.06 + bowlCurvature * (position.x * position.x + position.z * position.z)
    }

    mutating func start(target: EggDoneness, practice: Bool = false, catchPosition: SIMD3<Float> = Self.plateCatchPosition) {
        self = Self(); self.target = target; practiceMode = practice; phase = .cracking
        servingDestination = catchPosition
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
        if phase != .cooking { heatingMultiplier = 0; restingDuration = 0 }
    }

    private mutating func launch(_ flick: WokFlick) {
        restingDuration = 0; heatingMultiplier = 0
        if readyToServe && flick.spins == 2 {
            phase = .serving; phaseTime = 0; attempts += 1
            flightStartPosition = eggPosition
            servingStartRotation = eggRotation.rotation
            flightAxis = panRotation.rotation.act(flick.axis); flightSign = flick.sign
            flightDuration = 1.15
            rating = target.target.contains(sear[1]) && firstSideTarget.contains(sear[0]) ? (perfectFlips > 0 ? 3 : 2) : 1
            feedback = "Both sides are done — sending it to the plate!"
            return
        }
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
            // Contact-relative speed measures sliding/stirring, independently of
            // the phone's position or rotation. Accept tiny contact/sensor jitter.
            let relativeSpeed = simd_length(eggVelocity - surfaceVelocity)
            restingDuration = relativeSpeed < 0.04 ? restingDuration + Double(dt) : 0
            heatingMultiplier = practiceMode ? 0 : restingDuration >= 0.20 ? 2 : 1
            if !practiceMode { sear[contactSide] += Double(dt) * 0.05 * heat * heatingMultiplier }
            if sear[contactSide] >= 1 {
                heatingMultiplier = 0
                phase = .burnt; feedback = "The egg burned. Flip earlier and serve inside the target band."
            }
        } else if phase == .airborne {
            // Deliberate game assist: the flick chooses the spin count and a
            // controlled arc follows the moving bowl, returning to the opposite face.
            let progress = min(1, Float(phaseTime) / flightDuration)
            let blend = progress * progress * (3 - 2 * progress)
            let catchPosition = panPosition + q.act(SIMD3<Float>(0, Self.surfaceHeight(.zero), 0))
            let base = flightStartPosition + (catchPosition - flightStartPosition) * blend
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
                    : goodTiming ? "Perfect flip! Finish the other side." : sear[flightInitialSide] < (flightInitialSide == 0 ? firstSideMinimum : target.target.lowerBound) ? "Early flip — turn it back to finish searing that side." : "Nice flip! Watch the cooking target."
                localEgg = [0, Self.surfaceHeight(.zero), 0]
                eggPosition = catchPosition
                eggFaceRotation = simd_quatf(angle: flightSign * Float(lastFlipTurns * 2 + 1) * .pi, axis: flightAxis) * flatStart
                eggRotation = MotionQuaternion(q * eggFaceRotation)
                eggVelocity = panVelocity + simd_cross(panAngularVelocity, q.act(localEgg))
                phase = .cooking; phaseTime = 0
            }
        } else if phase == .serving {
            // Serving is an assisted ballistic throw to a fixed plate, independent
            // of subsequent wok movement. Stop searing as soon as it leaves the pan.
            let progress = min(1, Float(phaseTime) / flightDuration)
            let t = progress * flightDuration
            eggPosition = flightStartPosition + (servingDestination - flightStartPosition) * progress
                + SIMD3<Float>(0, Self.gravity * 0.5 * t * (flightDuration - t), 0)
            let blend = progress * progress * (3 - 2 * progress)
            let upright = simd_slerp(servingStartRotation, MotionQuaternion.identity.rotation, blend)
            eggRotation = MotionQuaternion(simd_quatf(angle: flightSign * 4 * .pi * progress, axis: flightAxis) * upright)
            if progress >= 1 {
                eggPosition = servingDestination; eggRotation = .identity; eggVelocity = .zero
                phase = .served; phaseTime = 0
                feedback = rating >= 2 ? "\(target.rawValue) egg, right on target. Caught on the plate!"
                    : "Caught on the plate! Past the target — try a little sooner next time."
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
/// pivot or amplification inside the free range. A circular stove support softly
/// resists outward movement, with no hidden displacement accumulating at the edge.
struct WokTranslationTracker: Sendable {
    static let horizontalLimit: Float = 0.22
    static let horizontalFreeRange: Float = 0.14
    static let liftLimit: Float = 0.12
    static let liftFreeRange: Float = 0.07
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
        var travel = (previousVelocity + velocity) * Float(dt * 0.5)
        let radius = simd_length(SIMD2<Float>(displacement.x, displacement.z))
        if radius > Self.horizontalFreeRange {
            let outward = SIMD3<Float>(displacement.x, 0, displacement.z) / radius
            let radialTravel = max(0, simd_dot(travel, outward))
            let remaining = (Self.horizontalLimit - radius) / (Self.horizontalLimit - Self.horizontalFreeRange)
            let resistance = Self.smoothResistance(remaining)
            // Preserve tangential stirring and inward travel; only outward travel resists.
            travel -= outward * radialTravel * (1 - resistance)
        }
        if travel.y > 0 && displacement.y > Self.liftFreeRange {
            travel.y *= Self.smoothResistance((Self.liftLimit - displacement.y) / (Self.liftLimit - Self.liftFreeRange))
        }
        displacement += travel
        let newRadius = simd_length(SIMD2<Float>(displacement.x, displacement.z))
        if newRadius > Self.horizontalLimit {
            displacement.x *= Self.horizontalLimit / newRadius
            displacement.z *= Self.horizontalLimit / newRadius
        }
        displacement.y = min(Self.liftLimit, max(0, displacement.y))
        previousVelocity = velocity
        return displacement
    }
    private static func smoothResistance(_ remaining: Float) -> Float {
        let t = min(1, max(0, remaining))
        return t * t * (3 - 2 * t)
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

/// Hands-free setup with forgiving hand tremor, hysteresis, and fresh sensor time.
struct WokStartCountdown: Sendable {
    static let holdDuration = 0.35
    static let countdownDuration = 3.0
    private(set) var steadyDuration = 0.0
    private(set) var elapsed = 0.0
    private(set) var isCounting = false
    private(set) var isLevel = false
    private var lastTimestamp: Double?
    private var unsettledDuration = 0.0
    var isReady: Bool { isCounting && elapsed >= Self.countdownDuration }
    var number: Int? { isCounting ? max(1, 3 - Int(elapsed)) : nil }
    mutating func reset() { self = Self() }

    mutating func update(_ sample: MotionSample) {
        guard sample.isValid else { reset(); return }
        let dt = lastTimestamp.map { sample.timestamp - $0 } ?? 0
        lastTimestamp = sample.timestamp
        let gravity = sample.gravity.magnitude
        let uprightScreen = gravity > 0.8 ? -sample.gravity.z / gravity : -1
        isLevel = uprightScreen > cos((isCounting ? 40.0 : 35.0) * .pi / 180)
        guard dt > 0, dt <= 0.2 else {
            steadyDuration = 0; elapsed = 0; isCounting = false; unsettledDuration = 0
            return
        }
        let acceleration = sample.acceleration.magnitude * Double(LinearMotionTracker.standardGravity)
        let gyro = sample.rotationRate.magnitude
        if !isCounting {
            if isLevel && gyro < 0.6 && acceleration < 0.9 {
                steadyDuration = min(Self.holdDuration, steadyDuration + dt)
                if steadyDuration >= Self.holdDuration { isCounting = true; elapsed = 0 }
            } else { steadyDuration = max(0, steadyDuration - dt * 2) }
            return
        }
        let comfortable = isLevel && gyro < 0.9 && acceleration < 1.2
        if comfortable {
            unsettledDuration = 0; elapsed = min(Self.countdownDuration, elapsed + dt)
        } else {
            unsettledDuration += dt // Brief tremor pauses the countdown without restarting it.
            if unsettledDuration > 0.25 || gyro > 2 || acceleration > 3 || uprightScreen < cos(50 * .pi / 180) {
                steadyDuration = 0; elapsed = 0; isCounting = false; unsettledDuration = 0
            }
        }
    }
}

struct WokEggResult: Identifiable, Sendable {
    let id: Int
    let target: EggDoneness
    let stars: Int
    let served: Bool
}

enum WokSessionPhase: Sendable { case idle, active, ended }

/// A session owns the score ledger and finished eggs; an engine owns one egg.
struct WokCookingSession: Sendable {
    private(set) var phase = WokSessionPhase.idle
    private(set) var generation: UInt64 = 0
    private(set) var eggNumber = 0
    private(set) var currentTarget: EggDoneness?
    private(set) var currentRecorded = false
    private(set) var results: [WokEggResult] = []
    var pile = WokServingPile()
    var averageStars: Double { results.isEmpty ? 0 : Double(results.reduce(0) { $0 + $1.stars }) / Double(results.count) }
    var servedCount: Int { pile.eggs.count }
    var perfectCount: Int { results.filter { $0.stars == 3 }.count }
    var canEnd: Bool { phase == .active }

    mutating func start() {
        let nextGeneration = generation &+ 1
        self = Self(); generation = nextGeneration; phase = .active
    }
    mutating func beginEgg<R: RandomNumberGenerator>(using random: inout R) -> EggDoneness? {
        guard phase == .active, eggNumber == 0 || currentRecorded else { return nil }
        eggNumber += 1; currentRecorded = false
        currentTarget = EggDoneness.allCases.randomElement(using: &random)
        return currentTarget
    }
    mutating func beginEgg() -> EggDoneness? {
        var random = SystemRandomNumberGenerator()
        return beginEgg(using: &random)
    }
    @discardableResult mutating func record(_ engine: WokGameEngine) -> WokEggResult? {
        guard phase == .active, eggNumber > 0, !currentRecorded, engine.finished, !engine.practiceMode, engine.target == currentTarget else { return nil }
        let result = WokEggResult(id: eggNumber, target: engine.target,
                                  stars: engine.phase == .served ? engine.rating : 0, served: engine.phase == .served)
        results.append(result); currentRecorded = true
        if result.served { pile.deposit(id: result.id, target: result.target, sear: engine.sear, stars: result.stars) }
        return result
    }
    @discardableResult mutating func end() -> Bool {
        guard phase == .active else { return false }
        if eggNumber > 0, !currentRecorded, let target = currentTarget {
            results.append(WokEggResult(id: eggNumber, target: target, stars: 0, served: false))
            currentRecorded = true
        }
        phase = .ended; return true
    }
}

struct WokPlatedEgg: Identifiable, Sendable {
    let id: Int
    let target: EggDoneness
    let sear: [Double]
    let stars: Int
    let onPlate: Bool
    var position: SIMD3<Float>
    var rotation = MotionQuaternion.identity
    var velocity = SIMD3<Float>.zero
    var angularVelocity = SIMD3<Float>.zero
}

/// Three broad, supported layers fit the plate. Later catches overhang that
/// support, tip outward, and become free rigid bodies on the counter. Fried-egg
/// deformation is approximated by a flattened ellipsoid and soft contact.
struct WokServingPile: Sendable {
    static let capacity = 3
    static let layerHeight: Float = 0.135
    static let tableHeight: Float = -0.5375
    private(set) var eggs: [WokPlatedEgg] = []
    var nextCatchPosition: SIMD3<Float> {
        let count = eggs.count
        if count < Self.capacity {
            return WokGameEngine.plateCatchPosition + SIMD3<Float>(Float(count) * 0.012, Float(count) * Self.layerHeight, Float(count) * 0.018)
        }
        // The top stack no longer offers support at the outer/front edge.
        return WokGameEngine.plateCatchPosition + SIMD3<Float>(0, 2 * Self.layerHeight + 0.025, 0.34)
    }
    mutating func deposit(id: Int, target: EggDoneness, sear: [Double], stars: Int) {
        let stable = eggs.count < Self.capacity
        var egg = WokPlatedEgg(id: id, target: target, sear: sear, stars: stars, onPlate: stable, position: nextCatchPosition)
        if !stable {
            let side: Float = eggs.count.isMultiple(of: 2) ? -1 : 1
            egg.velocity = [side * 0.14, 0.12, 1.05]
            egg.angularVelocity = [2.8, side * 0.6, side * 0.4]
        }
        eggs.append(egg)
    }
    mutating func step(_ deltaTime: Double) {
        guard deltaTime.isFinite, deltaTime > 0, deltaTime <= 0.1, eggs.count > Self.capacity else { return }
        let steps = max(1, Int(ceil(deltaTime * 240))), dt = Float(deltaTime) / Float(steps)
        for _ in 0..<steps {
            for index in Self.capacity..<eggs.count {
                var egg = eggs[index]
                egg.velocity.y -= WokGameEngine.gravity * dt
                egg.position += egg.velocity * dt
                let spin = simd_length(egg.angularVelocity)
                if spin > 0.0001 {
                    egg.rotation = MotionQuaternion(simd_quatf(angle: spin * dt, axis: egg.angularVelocity / spin) * egg.rotation.rotation)
                }
                // The plate rim deflects an overhanging body outward; it cannot
                // pass through the ceramic while falling toward the counter.
                let offset = egg.position - WokGameEngine.platePosition
                let radial = simd_length(SIMD2<Float>(offset.x, offset.z))
                if radial > 0.25 && radial < 0.59 && egg.position.y < WokGameEngine.platePosition.y + 0.12 {
                    let outward = SIMD3<Float>(offset.x, 0, offset.z) / radial
                    egg.velocity += outward * (5 * dt)
                    egg.position.y = max(egg.position.y, WokGameEngine.platePosition.y + 0.055)
                }
                let onCounter = abs(egg.position.x) < 2.25 && egg.position.z > -1.6 && egg.position.z < 2.2
                if onCounter {
                    let surface: Float = abs(egg.position.x) <= 1.85 && egg.position.z <= 1.85 && egg.position.z >= -1.25 ? Self.tableHeight : -0.57
                    let bottom = egg.position.y - Self.supportDepth(egg.rotation.rotation)
                    if bottom < surface {
                        egg.position.y += surface - bottom
                        let impulse = max(0, -egg.velocity.y)
                        egg.velocity.y = impulse > 0.25 ? impulse * 0.16 : 0
                        let tangent = SIMD3<Float>(egg.velocity.x, 0, egg.velocity.z), speed = simd_length(tangent)
                        if speed > 0.0001 { egg.velocity -= tangent / speed * min(speed, 0.48 * (impulse + WokGameEngine.gravity * dt)) }
                        egg.angularVelocity *= exp(-12 * dt)
                        egg.rotation = MotionQuaternion(simd_slerp(egg.rotation.rotation, simd_quatf(angle: 0, axis: [0, 1, 0]), min(1, 10 * dt)))
                    }
                }
                eggs[index] = egg
            }
            // Pair contacts allow spilled eggs to bump and pile on each other.
            // Equal masses share normal impulses; supported plate layers stay put.
            if eggs.count > Self.capacity + 1 {
                for first in Self.capacity..<(eggs.count - 1) {
                    for second in (first + 1)..<eggs.count {
                        var a = eggs[first], b = eggs[second]
                        let horizontal = SIMD3<Float>(b.position.x - a.position.x, 0, b.position.z - a.position.z)
                        let distance = simd_length(horizontal), height = b.position.y - a.position.y
                        guard distance < 0.52 && abs(height) < Self.layerHeight else { continue }
                        if distance < 0.25 && abs(height) > 0.055 {
                            let upperIsB = height > 0
                            var upper = upperIsB ? b : a
                            let lower = upperIsB ? a : b
                            upper.position.y = lower.position.y + Self.layerHeight
                            if upper.velocity.y < 0 { upper.velocity.y *= -0.12 }
                            upper.velocity.x *= exp(-5 * dt); upper.velocity.z *= exp(-5 * dt)
                            upper.angularVelocity *= exp(-8 * dt)
                            upper.rotation = MotionQuaternion(simd_slerp(upper.rotation.rotation, MotionQuaternion.identity.rotation, min(1, 8 * dt)))
                            if upperIsB { b = upper } else { a = upper }
                        } else {
                            let normal = distance > 0.00001 ? horizontal / distance : SIMD3<Float>(1, 0, 0)
                            let correction = normal * (0.52 - distance) * 0.5
                            a.position -= correction; b.position += correction
                            let closing = simd_dot(b.velocity - a.velocity, normal)
                            if closing < 0 {
                                let impulse = normal * (-closing * 0.58)
                                a.velocity -= impulse; b.velocity += impulse
                            }
                        }
                        eggs[first] = a; eggs[second] = b
                    }
                }
            }
        }
    }
    private static func supportDepth(_ q: simd_quatf) -> Float {
        let right = q.act(SIMD3<Float>(1, 0, 0)), up = q.act(SIMD3<Float>(0, 1, 0)), forward = q.act(SIMD3<Float>(0, 0, 1))
        return sqrt(pow(right.y * 0.33, 2) + pow(up.y * 0.075, 2) + pow(forward.y * 0.27, 2)) - up.y * 0.055
    }
}

/// End at any point: top edge folded down, or screen facing the floor.
/// A brief sensor-clock hold rejects transient flicks, stale frames, and gaps.
struct WokEndSessionGesture: Sendable {
    static let holdDuration = 0.20
    private(set) var held = 0.0
    private var lastTimestamp: Double?
    mutating func reset() { self = Self() }
    mutating func update(_ sample: MotionSample, allowed: Bool) -> Bool {
        guard allowed, sample.isValid else { reset(); return false }
        let dt = lastTimestamp.map { sample.timestamp - $0 } ?? 0
        lastTimestamp = sample.timestamp
        guard dt > 0 && dt <= 0.2 else { held = 0; return false }
        let gravity = sample.gravity.magnitude
        let downward = gravity > 0.8 && (sample.gravity.y / gravity > sin(55.0 * .pi / 180)
                                         || sample.gravity.z / gravity > 0.60)
        if downward { held += dt } else { held = 0 }
        return held >= Self.holdDuration
    }
}
