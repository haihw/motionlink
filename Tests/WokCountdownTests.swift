import Testing
@testable import MotionLinkCore

private func holdSample(_ time: Double, gyro: Double = 0.4, acceleration: Double = 0.06, gravity: MotionVector = MotionVector(x: 0, y: 0, z: -1)) -> MotionSample {
    MotionSample(sequence: 1, timestamp: time, attitude: .identity,
                 rotationRate: MotionVector(x: gyro, y: 0, z: 0),
                 acceleration: MotionVector(x: acceleration, y: 0, z: 0), gravity: gravity)
}

@Test("A relaxed hand starts the 3–2–1 countdown and becomes ready without a click")
func relaxedWokCountdown() {
    var monitor = WokStartCountdown()
    var numbers: Set<Int> = []
    for tick in 0...210 {
        monitor.update(holdSample(Double(tick) / 60))
        if let number = monitor.number { numbers.insert(number) }
        if tick == 24 { #expect(monitor.number == 3 && !monitor.isReady) }
        if tick == 84 { #expect(monitor.number == 2 && !monitor.isReady) }
        if tick == 144 { #expect(monitor.number == 1 && !monitor.isReady) }
    }
    #expect(numbers == [1, 2, 3])
    #expect(monitor.isReady)
}

@Test("Brief hand tremor pauses the countdown without restarting its progress")
func countdownToleratesTremor() {
    var monitor = WokStartCountdown()
    for tick in 0...60 { monitor.update(holdSample(Double(tick) / 60)) }
    let progress = monitor.elapsed
    for tick in 61...66 { monitor.update(holdSample(Double(tick) / 60, gyro: 1.1, acceleration: 0.14)) }
    #expect(monitor.isCounting && monitor.elapsed == progress)
    for tick in 67...80 { monitor.update(holdSample(Double(tick) / 60)) }
    #expect(monitor.elapsed > progress)
}

@Test("Sustained or strong movement cancels the countdown")
func countdownMovementCancels() {
    var monitor = WokStartCountdown()
    for tick in 0...60 { monitor.update(holdSample(Double(tick) / 60)) }
    for tick in 61...80 { monitor.update(holdSample(Double(tick) / 60, gyro: 1.1)) }
    #expect(!monitor.isCounting && !monitor.isReady)
    for tick in 81...110 { monitor.update(holdSample(Double(tick) / 60)) }
    #expect(monitor.isCounting)
    monitor.update(holdSample(111.0 / 60, gyro: 2.5))
    #expect(!monitor.isCounting && monitor.elapsed == 0)
}

@Test("A stream gap discards countdown progress; old clocks cannot finish it")
func countdownNeedsFreshMotion() {
    var monitor = WokStartCountdown()
    for tick in 0...120 { monitor.update(holdSample(Double(tick) / 60)) }
    #expect(monitor.isCounting)
    monitor.update(holdSample(5))
    #expect(!monitor.isCounting && !monitor.isReady)
    monitor.update(holdSample(4.9))
    #expect(!monitor.isCounting)
    monitor.reset()
    #expect(monitor.elapsed == 0 && monitor.steadyDuration == 0)
}

@Test("An upright or actively moving phone never starts automatically")
func unsuitableWokHold() {
    for gravity in [MotionVector(x: 0, y: -1, z: 0), MotionVector(x: 0, y: 0, z: 1)] {
        var monitor = WokStartCountdown()
        for tick in 0...240 { monitor.update(holdSample(Double(tick) / 60, gravity: gravity)) }
        #expect(!monitor.isCounting && !monitor.isReady)
    }
    var moving = WokStartCountdown()
    for tick in 0...240 { moving.update(holdSample(Double(tick) / 60, acceleration: 0.2)) }
    #expect(!moving.isCounting)
}
