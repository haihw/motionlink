import simd

/// A comfortable grip defines neutral, with tilt axes aligned to gravity.
struct TiltPose: Sendable {
    let reference: MotionQuaternion
    let controlToDevice: MotionQuaternion
    static func canCapture(_ sample: MotionSample) -> Bool {
        sample.isValid && (0.8...1.2).contains(sample.gravity.magnitude)
            && sample.rotationRate.magnitude < 0.65 && sample.acceleration.magnitude < 0.2
    }
    init(_ sample: MotionSample) {
        reference = sample.attitude
        let up = simd_normalize(-sample.gravity.simdValue)
        let alignment = up.z < -0.9999 ? simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
            : simd_quatf(from: SIMD3<Float>(0, 0, 1), to: up)
        controlToDevice = MotionQuaternion(alignment)
    }
    func gravity(_ sample: MotionSample) -> SIMD3<Float> {
        let relative = sample.attitude.relative(to: reference).rotation
        let control = controlToDevice.rotation.inverse * relative * controlToDevice.rotation
        return control.inverse.act(SIMD3<Float>(0, 0, -1))
    }
    static func angles(_ gravity: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(atan2(gravity.x, -gravity.z), atan2(gravity.y, -gravity.z)) * (180 / .pi)
    }
}

enum TiltPhysics {
    /// Exact damped integration under a constant g·sin(tilt) input. Paper Y is down.
    static func travel(gravity: SIMD3<Float>, velocity: inout SIMD2<Float>, dt: Double, sensitivity: Float) -> SIMD2<Float> {
        var downhill = SIMD2(gravity.x, -gravity.y)
        let magnitude = simd_length(downhill)
        let deadZone = sin(Float(1.5 * Double.pi / 180))
        let amount = min(sin(Float(55 * Double.pi / 180)), max(0, magnitude - deadZone) / (1 - deadZone))
        downhill = magnitude > 0.0001 ? downhill / magnitude * amount : .zero
        let gain = sensitivity.isFinite ? min(2, max(0.4, sensitivity)) : 1
        let terminal = downhill * 640 * gain
        let drag: Float = amount == 0 ? 22 : 7.5
        let response = exp(-drag * Float(dt))
        let travel = velocity * ((1 - response) / drag) + terminal * (Float(dt) - (1 - response) / drag)
        velocity = terminal + (velocity - terminal) * response
        return travel
    }
}
