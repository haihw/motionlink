import Testing
@testable import MotionLinkCore

private func neutralSample(time: Double, gravity: MotionVector = MotionVector(x: 0, y: -1, z: 0), acceleration: MotionVector = .zero, gyro: MotionVector = .zero) -> MotionSample {
    MotionSample(sequence: 1, timestamp: time, attitude: .identity, rotationRate: gyro, acceleration: acceleration, gravity: gravity)
}

@Test("Neutral readiness requires a continuous upright steady hold")
func neutralHold() {
    var monitor = NeutralPoseMonitor()
    #expect(!monitor.update(neutralSample(time: 1)).isReady)
    for tick in 1...35 { #expect(!monitor.update(neutralSample(time: 1 + Double(tick) / 60)).isReady) }
    #expect(monitor.update(neutralSample(time: 1.7)).isReady)
    monitor.reset()
    #expect(!monitor.update(neutralSample(time: 1.8)).isReady)
}

@Test("Flat, upside-down, and sideways postures cannot pass neutral setup")
func wrongNeutralPosture() {
    for gravity in [MotionVector(x: 0, y: 0, z: -1), MotionVector(x: 0, y: 1, z: 0), MotionVector(x: -1, y: 0, z: 0)] {
        var monitor = NeutralPoseMonitor()
        for tick in 0...50 {
            let check = monitor.update(neutralSample(time: 1 + Double(tick) / 60, gravity: gravity))
            #expect(!check.isUpright && !check.isReady)
        }
    }
}

@Test("Motion interrupts the neutral hold even when the phone is upright")
func movingNeutralPhone() {
    var monitor = NeutralPoseMonitor()
    for tick in 0...45 { _ = monitor.update(neutralSample(time: 1 + Double(tick) / 60)) }
    #expect(monitor.update(neutralSample(time: 1.8, gyro: MotionVector(x: 0.2, y: 0, z: 0))).stableDuration == 0)
    #expect(!monitor.update(neutralSample(time: 1.9, acceleration: MotionVector(x: 0.04, y: 0, z: 0))).isStill)
    #expect(!monitor.update(neutralSample(time: 2)).isReady)
}

@Test("Timestamp gaps and out-of-order samples discard neutral readiness")
func interruptedNeutralHold() {
    var monitor = NeutralPoseMonitor()
    for tick in 0...45 { _ = monitor.update(neutralSample(time: 1 + Double(tick) / 60)) }
    #expect(!monitor.update(neutralSample(time: 2.5)).isReady)
    #expect(monitor.update(neutralSample(time: 2.4)).stableDuration == 0)
    var invalid = neutralSample(time: 2.5); invalid.attitude.w = 0
    #expect(!monitor.update(invalid).isReady)
    #expect(!monitor.update(neutralSample(time: 2.6)).isReady)
}
