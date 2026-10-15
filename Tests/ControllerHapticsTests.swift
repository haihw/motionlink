import Foundation
import Testing
@testable import MotionLinkCore

@Test("Protocol 3 transports capabilities, custom patterns, commands, and lifecycle responses")
func hapticWireRoundTrip() throws {
    let pattern = HapticPattern(events: [HapticEvent(kind: .continuous, duration: 1, intensity: 0.7, sharpness: 0.2)],
                                curves: [HapticCurve(parameter: .intensityScale, points: [.init(time: 0, value: 0), .init(time: 0.1, value: 1), .init(time: 1, value: 0)])])
    let playback = HapticPlayback(pattern: pattern, delay: 0.2, loop: true, lifetime: 3)
    let command = HapticCommand(action: .play, playback: playback)
    let response = HapticResponse(requestID: command.requestID, playbackID: playback.id, status: .accepted)
    let capabilities = HapticCapabilities(supportsHaptics: true)
    let frames = try FrameDecoder.encode(LinkMessage(kind: .hello, hapticCapabilities: capabilities))
        + FrameDecoder.encode(LinkMessage(kind: .hapticCommand, hapticCommand: command))
        + FrameDecoder.encode(LinkMessage(kind: .hapticResponse, hapticResponse: response))
    #expect(LinkMessage.protocolVersion == 3 && playback.isValid)
    for split in stride(from: 0, through: frames.count, by: 13) {
        var decoder = FrameDecoder()
        let messages = try decoder.append(Data(frames.prefix(split))) + decoder.append(Data(frames.dropFirst(split)))
        #expect(messages.count == 3)
        #expect(messages[0].hapticCapabilities == capabilities)
        #expect(messages[1].hapticCommand == command)
        #expect(messages[2].hapticResponse == response)
    }
}

@Test("Malformed haptic events, curves, leases, and command combinations are rejected")
func invalidHapticPayloads() {
    #expect(!HapticPattern(events: []).isValid)
    #expect(!HapticPattern.impact(intensity: 1.01).isValid)
    #expect(!HapticPattern.impact(sharpness: .nan).isValid)
    #expect(!HapticPattern.rumble(duration: -.infinity).isValid)
    #expect(!HapticPattern(events: Array(repeating: HapticEvent(kind: .transient), count: 65)).isValid)
    #expect(!HapticCurve(parameter: .intensityScale, points: [.init(time: 0, value: 1), .init(time: 0, value: 0)]).isValid)
    #expect(!HapticCurve(parameter: .sharpnessOffset, points: [.init(time: 0, value: -2), .init(time: 1, value: 0)]).isValid)
    #expect(!HapticPlayback(pattern: .rumble(duration: 2), lifetime: 1).isValid)
    #expect(!HapticPlayback(pattern: .impact(), delay: 2, loop: true, lifetime: 2).isValid)
    #expect(!HapticPlayback(pattern: .rumble(), loop: true, lifetime: 31).isValid)
    #expect(!HapticCommand(action: .play).isValid)
    #expect(!HapticCommand(action: .stopAll, playbackID: UUID()).isValid)
    #expect(!HapticCommand(action: .update, playbackID: UUID(), parameters: HapticParameters()).isValid)
    #expect(!HapticParameters(playbackRate: 4).isValid)
    #expect(!HapticParameters(intensityScale: -.infinity).isValid)
}

@Test("A worst-case supported pattern fits the bounded transport frame")
func hapticPayloadBudget() throws {
    let events = (0..<64).map { HapticEvent(kind: .transient, time: Double($0) * 0.1, intensity: 0.8, sharpness: 0.3) }
    let points = (0..<16).map { HapticCurve.Point(time: Double($0) * 0.4, value: Float($0 % 2)) }
    let pattern = HapticPattern(events: events, curves: [HapticCurve(parameter: .intensityScale, points: points), HapticCurve(parameter: .sharpnessOffset, points: points)])
    let playback = HapticPlayback(pattern: pattern, lifetime: 10)
    #expect(playback.isValid)
    let bytes = try FrameDecoder.encode(LinkMessage(kind: .hapticCommand, hapticCommand: HapticCommand(action: .play, playback: playback)))
    #expect(bytes.count <= FrameDecoder.maximumPayload + 4)
}

@Test("Capabilities distinguish unsupported hardware, disabled feedback, and unavailable channels")
func hapticCapabilities() {
    let playback = HapticPlayback(pattern: .success)
    #expect(HapticCapabilities(supportsHaptics: true).supports(playback))
    #expect(!HapticCapabilities(supportsHaptics: false).supports(playback))
    #expect(!HapticCapabilities(supportsHaptics: true, isEnabled: false).supports(playback))
    let otherChannel = HapticPlayback(channel: "leftTrigger", pattern: .impact())
    #expect(otherChannel.isValid)
    #expect(!HapticCapabilities(supportsHaptics: true).supports(otherChannel))
    #expect(!HapticCapabilities(supportsHaptics: true, channels: ["main", "main"]).isValid)
}

@Test("Rate limiting and duplicate protection cannot block stop-all")
func hapticRateLimit() {
    var gate = HapticCommandGate()
    let original = HapticCommand(action: .play, playback: HapticPlayback(pattern: .impact()))
    let first = gate.check(original, time: 0), duplicate = gate.check(original, time: 0)
    #expect(first == nil && duplicate == .duplicateRequest)
    for _ in 0..<19 { let reason = gate.check(HapticCommand(action: .play, playback: HapticPlayback(pattern: .impact())), time: 0); #expect(reason == nil) }
    let throttled = gate.check(HapticCommand(action: .play, playback: HapticPlayback(pattern: .impact())), time: 0)
    let stopped = gate.check(HapticCommand(action: .stopAll), time: 0)
    let recovered = gate.check(HapticCommand(action: .play, playback: HapticPlayback(pattern: .impact())), time: 1)
    #expect(throttled == .rateLimited && stopped == nil && recovered == nil)
}

@Test("Scripted envelopes and live control ownership are explicit")
func hapticCurveOwnership() {
    let pattern = HapticPattern(events: [HapticEvent(kind: .continuous, duration: 1)], curves: [HapticCurve(parameter: .intensityScale, points: [.init(time: 0, value: 0), .init(time: 1, value: 1)])])
    #expect(HapticPlayback(pattern: pattern).isValid)
    #expect(!HapticPlayback(pattern: pattern, parameters: HapticParameters(intensityScale: 0.5)).isValid)
    #expect(HapticPlayback(pattern: pattern, parameters: HapticParameters(playbackRate: 0.8)).isValid)
}

@MainActor private final class HapticTransportFixture {
    let client = ControllerHaptics()
    var commands: [HapticCommand] = []
    init() {
        client.connect(capabilities: HapticCapabilities(supportsHaptics: true)) { [weak self] command in
            self?.commands.append(command); return true
        }
    }
    func reply(_ index: Int, _ status: HapticResponse.Status, reason: HapticResponse.Reason? = nil) {
        let command = commands[index]
        client.receive(HapticResponse(requestID: command.requestID, playbackID: command.playback?.id ?? command.playbackID, status: status, reason: reason))
    }
}

@Test("Host play/update/stop preserve playback identity and use acknowledged lifecycle state")
@MainActor func hapticHostLifecycle() throws {
    let fixture = HapticTransportFixture(); defer { fixture.client.disconnect() }
    let id = try #require(fixture.client.play(.rumble(), loop: true, lifetime: 4))
    fixture.reply(0, .accepted)
    #expect(fixture.client.activePlayers.contains(id))
    #expect(fixture.client.update(id, parameters: HapticParameters(intensityScale: 0.2, sharpnessOffset: 0.3, playbackRate: 1.5)))
    fixture.reply(1, .updated)
    #expect(fixture.commands[1].playbackID == id && fixture.client.activePlayers.contains(id))
    #expect(fixture.client.stop(id))
    fixture.reply(2, .stopped)
    #expect(fixture.client.activePlayers.isEmpty && fixture.client.lastResponse?.status == .stopped)
}

@Test("Rejected updates do not forget an existing player; expiration removes it")
@MainActor func hapticRejectedUpdate() throws {
    let fixture = HapticTransportFixture(); defer { fixture.client.disconnect() }
    let id = try #require(fixture.client.play(.rumble(), loop: true, lifetime: 4))
    fixture.reply(0, .accepted)
    fixture.client.update(id, parameters: HapticParameters(intensityScale: 0.4))
    fixture.reply(1, .rejected, reason: .engineError)
    #expect(fixture.client.activePlayers.contains(id))
    fixture.reply(0, .expired)
    #expect(fixture.client.activePlayers.isEmpty)
}

@Test("Stop-all bypasses a saturated update budget and coalesces repeat stops")
@MainActor func hapticHostStopUnderLoad() throws {
    let fixture = HapticTransportFixture(); defer { fixture.client.disconnect() }
    let id = try #require(fixture.client.play(.rumble(), loop: true, lifetime: 4))
    fixture.reply(0, .accepted)
    for _ in 0..<30 { fixture.client.update(id, parameters: HapticParameters(intensityScale: 0.4)) }
    let before = fixture.commands.count
    #expect(fixture.client.stopAll())
    #expect(fixture.commands.count == before + 1)
    #expect(fixture.client.stopAll())
    #expect(fixture.commands.count == before + 1)
    fixture.reply(before, .stopped)
    #expect(fixture.client.activePlayers.isEmpty)
}

@Test("Disconnect clears capability, active players, pending requests, and stale replies")
@MainActor func hapticHostDisconnect() throws {
    let fixture = HapticTransportFixture()
    _ = try #require(fixture.client.play(.impact()))
    fixture.client.disconnect()
    #expect(!fixture.client.isAvailable && fixture.client.activePlayers.isEmpty)
    fixture.reply(0, .accepted)
    #expect(fixture.client.activePlayers.isEmpty)
    #expect(fixture.client.play(.impact()) == nil)
}
