import simd
import Testing

private func requireTarget(_ value: EggDoneness?) throws -> EggDoneness { try #require(value) }
private func expectFalse(_ value: Bool) { #expect(!value) }
private func expectTrue(_ value: Bool) { #expect(value) }
@testable import MotionLinkCore

private struct SessionRandom: RandomNumberGenerator {
    var state: UInt64 = 42
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}

private func finishedSessionEgg(target: EggDoneness, catchPosition: SIMD3<Float> = WokGameEngine.plateCatchPosition) -> WokGameEngine {
    var engine = WokGameEngine(); engine.start(target: target, catchPosition: catchPosition)
    for tick in 0..<3600 {
        engine.step(deltaTime: 1.0 / 60, input: .autoplay(engine: engine, sampleID: UInt64(tick)))
        if engine.finished { break }
    }
    return engine
}

private func sessionFoldSample(_ tick: Int, folded: Bool = true) -> MotionSample {
    MotionSample(sequence: UInt64(tick), timestamp: Double(tick) / 60, attitude: .identity,
                 rotationRate: .zero, acceleration: .zero,
                 gravity: folded ? MotionVector(x: 0, y: 0.94, z: -0.342) : MotionVector(x: 0, y: 0, z: -1))
}

@Test("Restart clears session scores and every plated egg")
func wokSessionRestart() throws {
    var session = WokCookingSession(); session.start()
    let target = try requireTarget(session.beginEgg())
    let engine = finishedSessionEgg(target: target)
    #expect(session.record(engine)?.stars == 3)
    #expect(session.servedCount == 1 && session.averageStars == 3)
    let generation = session.generation
    session.start()
    #expect(session.phase == .active && session.generation != generation)
    #expect(session.results.isEmpty && session.pile.eggs.isEmpty && session.eggNumber == 0)
    #expect(session.averageStars == 0 && session.canEnd)
}

@Test("Each new egg draws a random request and cannot advance before completion")
func wokRandomSessionRequests() throws {
    var session = WokCookingSession(), twin = WokCookingSession()
    var random = SessionRandom(), twinRandom = SessionRandom()
    session.start(); twin.start()
    var drawn: Set<EggDoneness> = []
    for _ in 0..<16 {
        let target = try requireTarget(session.beginEgg(using: &random))
        #expect(twin.beginEgg(using: &twinRandom) == target)
        #expect(session.beginEgg(using: &random) == nil)
        drawn.insert(target)
        let engine = finishedSessionEgg(target: target, catchPosition: session.pile.nextCatchPosition)
        #expect(session.record(engine) != nil)
        #expect(twin.record(engine) != nil)
    }
    #expect(drawn == Set(EggDoneness.allCases))
    #expect(session.results.count == 16 && session.eggNumber == 16)
}

@Test("One egg cannot be scored or deposited twice across repeated result frames")
func wokSessionDeduplication() throws {
    var session = WokCookingSession(); session.start()
    let target = try requireTarget(session.beginEgg())
    var raw = WokGameEngine(); raw.start(target: target)
    #expect(session.record(raw) == nil && session.canEnd)
    let engine = finishedSessionEgg(target: target)
    #expect(session.record(engine) != nil)
    for _ in 0..<100 { #expect(session.record(engine) == nil) }
    #expect(session.results.count == 1 && session.pile.eggs.count == 1)
    #expect(session.end() && session.phase == .ended)
    #expect(session.beginEgg() == nil && session.record(engine) == nil)
    #expect(session.servedCount == 1 && session.averageStars == 3)
}

@Test("The session average includes failed eggs as zero stars")
func wokSessionFailureAverage() throws {
    var session = WokCookingSession(); session.start()
    let goodTarget = try requireTarget(session.beginEgg())
    session.record(finishedSessionEgg(target: goodTarget))
    let badTarget = try requireTarget(session.beginEgg())
    var burnt = WokGameEngine(); burnt.start(target: badTarget)
    for tick in 0..<1800 {
        burnt.step(deltaTime: 1.0 / 60, input: WokInput(sampleID: UInt64(tick)))
        if burnt.finished { break }
    }
    #expect(burnt.phase == .burnt)
    #expect(session.record(burnt)?.stars == 0)
    #expect(session.averageStars == 1.5 && session.results.count == 2 && session.servedCount == 1)
    #expect(session.end() && session.perfectCount == 1)
}

@Test("Ending before the first egg does not invent an unfinished egg")
func wokEndBeforeFirstEgg() {
    var session = WokCookingSession(); session.start()
    expectTrue(session.end())
    #expect(session.phase == .ended && session.results.isEmpty && session.averageStars == 0)
}

@Test("Ending during cracking, cooking, flipping, or serving scores the unfinished egg zero", arguments: [WokPhase.cracking, .cooking, .airborne, .serving])
func wokEndUnfinishedEgg(phase: WokPhase) throws {
    var session = WokCookingSession(); session.start()
    let goodTarget = try requireTarget(session.beginEgg())
    session.record(finishedSessionEgg(target: goodTarget))
    let target = try requireTarget(session.beginEgg())
    var unfinished = WokGameEngine(); unfinished.start(target: target)
    for tick in 0..<3600 {
        if unfinished.phase == phase { break }
        unfinished.step(deltaTime: 1.0 / 60, input: .autoplay(engine: unfinished, sampleID: UInt64(tick)))
    }
    #expect(unfinished.phase == phase && !unfinished.finished)
    #expect(session.record(unfinished) == nil)
    expectTrue(session.end())
    #expect(session.results.map(\.stars) == [3, 0])
    #expect(session.results.last?.target == target && session.results.last?.served == false)
    #expect(session.averageStars == 1.5 && session.servedCount == 1)
    expectFalse(session.end())
    #expect(session.record(finishedSessionEgg(target: target)) == nil)
    #expect(session.results.count == 2 && session.servedCount == 1)
}

@Test("Exactly three eggs form separate stable plate layers; the fourth overhangs")
func wokThreeEggPlate() {
    var pile = WokServingPile()
    for index in 0..<3 {
        let expected = pile.nextCatchPosition
        pile.deposit(id: index, target: .medium, sear: [0.61, 0.4], stars: 3)
        #expect(pile.eggs[index].position == expected && pile.eggs[index].onPlate)
        if index > 0 { #expect(pile.eggs[index].position.y - pile.eggs[index - 1].position.y >= 0.13) }
    }
    let supported = pile.eggs.map(\.position)
    pile.deposit(id: 3, target: .soft, sear: [0.61, 0.25], stars: 3)
    #expect(!pile.eggs[3].onPlate && pile.eggs[3].velocity.z > 0)
    let airborne = pile.eggs[3].position
    for _ in 0..<240 { pile.step(1.0 / 60) }
    #expect(Array(pile.eggs.prefix(3)).map(\.position) == supported)
    let spilled = pile.eggs[3]
    #expect(spilled.position.y < airborne.y - 0.2)
    #expect(spilled.position.z > WokGameEngine.platePosition.z + 0.53)
    #expect(abs(spilled.position.y - (WokServingPile.tableHeight + 0.02)) < 0.03)
    #expect(simd_length(spilled.velocity) < 0.05)
    #expect(spilled.rotation.rotation.act(SIMD3<Float>(0, 1, 0)).y > 0.95)
}

@Test("Overflow bodies collide and settle on the table without erasing earlier eggs")
func wokOverflowContacts() {
    var pile = WokServingPile()
    for index in 0..<7 {
        pile.deposit(id: index, target: .medium, sear: [0.61, 0.4], stars: 3)
        for _ in 0..<180 { pile.step(1.0 / 60) }
    }
    #expect(pile.eggs.count == 7)
    #expect(pile.eggs.filter(\.onPlate).count == 3)
    for egg in pile.eggs.dropFirst(3) {
        #expect(egg.position.x.isFinite && egg.position.y.isFinite && egg.position.z.isFinite)
        #expect(egg.position.y > -0.60 && egg.position.y < 0)
        #expect(simd_length(egg.velocity) < 0.15)
    }
    let positions = pile.eggs.map(\.position)
    pile.step(2); pile.step(.nan)
    #expect(pile.eggs.map(\.position) == positions)
}

@Test("Serving targets the next plate layer instead of overwriting the previous egg")
func wokRaisedPlateCatch() {
    var pile = WokServingPile()
    for index in 0..<4 {
        let destination = pile.nextCatchPosition
        let engine = finishedSessionEgg(target: .soft, catchPosition: destination)
        #expect(engine.phase == .served && engine.eggPosition == destination && engine.rating == 3)
        pile.deposit(id: index, target: .soft, sear: engine.sear, stars: engine.rating)
        #expect(pile.eggs[index].position == destination)
    }
}

@Test("A brief held downward fold ends any active session and rejects transient flicks")
func wokEndFoldHold() {
    var gesture = WokEndSessionGesture()
    for tick in 0..<60 { expectFalse(gesture.update(sessionFoldSample(tick), allowed: false)) }
    for tick in 60..<72 { expectFalse(gesture.update(sessionFoldSample(tick), allowed: true)) }
    expectTrue(gesture.update(sessionFoldSample(74), allowed: true))
    gesture.reset()
    for tick in 0..<8 { expectFalse(gesture.update(sessionFoldSample(tick), allowed: true)) }
    expectFalse(gesture.update(sessionFoldSample(8, folded: false), allowed: true))
    #expect(gesture.held == 0)
    for tick in 9..<20 { expectFalse(gesture.update(sessionFoldSample(tick), allowed: true)) }
}

@Test("A level hold, upright phone, stale timestamps, and stream gaps do not end a session")
func wokEndFoldRejectsFalsePositives() {
    var gesture = WokEndSessionGesture()
    for tick in 0..<90 { expectFalse(gesture.update(sessionFoldSample(tick, folded: false), allowed: true)) }
    var upright = sessionFoldSample(90); upright.gravity = MotionVector(x: 0, y: -1, z: 0)
    for tick in 90..<160 { upright.timestamp = Double(tick) / 60; expectFalse(gesture.update(upright, allowed: true)) }
    gesture.reset()
    for tick in 0..<10 { expectFalse(gesture.update(sessionFoldSample(tick), allowed: true)) }
    expectFalse(gesture.update(sessionFoldSample(100), allowed: true)); #expect(gesture.held == 0)
    for _ in 0..<90 { expectFalse(gesture.update(sessionFoldSample(100), allowed: true)) }
    #expect(gesture.held == 0)
}


@Test("Top-edge-down and fully face-down positions both stop, even during a fast fold", arguments: [MotionVector(x: 0, y: 0.94, z: -0.342), MotionVector(x: 0, y: 0, z: 1), MotionVector(x: 0, y: 0.85, z: 0.52)])
func wokFoldPostures(gravity: MotionVector) {
    var gesture = WokEndSessionGesture()
    var ended = false
    for tick in 0..<18 {
        var sample = sessionFoldSample(tick)
        sample.gravity = gravity; sample.rotationRate = MotionVector(x: 2.5, y: 0, z: 0)
        ended = gesture.update(sample, allowed: true) || ended
    }
    #expect(ended)
}
