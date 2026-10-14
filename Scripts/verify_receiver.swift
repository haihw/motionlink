import Foundation
import Network
import simd

/// Exercises the production Mac receiver over real TCP without a GUI or sensors.
/// Compile with the shared sources and macOS/MacSession.swift (see README).
@main @MainActor
struct ReceiverVerification {
    static func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "MotionLinkVerification", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out: \(description)"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func require(_ condition: Bool, _ description: String) throws {
        guard condition else { throw NSError(domain: "MotionLinkVerification", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: description]) }
    }
    static func client(port: NWEndpoint.Port, code: String, log: MessageLog) -> LinkConnection {
        let channel = LinkConnection(NWConnection(host: "127.0.0.1", port: port, using: LinkSettings.parameters()))
        channel.onReady = { [weak channel] in channel?.send(LinkMessage(kind: .hello, code: code, deviceName: "Verification iPhone")) }
        channel.onMessage = { message in log.messages.append(message) }
        channel.onClose = { _ in log.closed = true }
        channel.start()
        return channel
    }
    static func main() async throws {
        let receiver = MacSession()
        receiver.macName = "MotionLink Verification \(UUID().uuidString.prefix(8))"
        receiver.start()
        defer { receiver.stop() }
        try await waitUntil("receiver listening") { receiver.isListening }
        guard let port = receiver.listeningPort else { throw NSError(domain: "MotionLinkVerification", code: 3) }
        let wrongLog = MessageLog()
        let wrong = client(port: port, code: "invalid", log: wrongLog)
        try await waitUntil("wrong code rejected") { wrongLog.closed }
        try require(wrongLog.messages.contains { $0.kind == .rejected }, "Wrong pairing code was not rejected")
        try require(receiver.deviceName == nil, "Wrong pairing code acquired the receiver")
        wrong.close()

        let pairedCode = receiver.pairingCode
        let log = MessageLog()
        let sender = client(port: port, code: receiver.pairingCode, log: log)
        defer { sender.close() }
        try await waitUntil("correct pairing accepted") { log.messages.contains { $0.kind == .accepted } }
        try require(receiver.deviceName == "Verification iPhone", "Paired device was not recorded")
        let busyLog = MessageLog()
        let busy = client(port: port, code: receiver.pairingCode, log: busyLog)
        try await waitUntil("second phone rejected") { busyLog.closed }
        busy.close()
        try require(receiver.deviceName == "Verification iPhone", "A second phone took over")

        var sample = MotionSample(sequence: 1, timestamp: 1, attitude: .identity,
                                  rotationRate: .zero, acceleration: .zero, gravity: MotionVector(x: 0, y: -1, z: 0))
        sender.send(LinkMessage(kind: .motion, sample: sample))
        try await waitUntil("first motion received") { receiver.sample?.sequence == 1 }
        try require(!receiver.isNeutralConfirmed, "First sample bypassed neutral confirmation")
        sample.sequence = 2
        sample.timestamp += 1.0 / 60
        sample.acceleration = MotionVector(x: 0.2, y: 0, z: 0)
        sample.attitude = MotionQuaternion(simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        sender.send(LinkMessage(kind: .motion, sample: sample))
        try await waitUntil("rotation received") { receiver.sample?.sequence == 2 }
        try require(abs(simd_dot(receiver.orientation.rotation.vector, sample.attitude.rotation.vector)) > 0.9999, "Model rotation does not match motion")
        try require(receiver.movement.isAvailable && receiver.movement.acceleration.z < -0.5,
                    "Tilted acceleration was not transformed into the neutral frame")
        sender.send(LinkMessage(kind: .resetMovement))
        try await waitUntil("speed reset received") { !receiver.movement.isAvailable }
        sample.sequence = 3; sample.timestamp += 1.0 / 60
        sender.send(LinkMessage(kind: .motion, sample: sample))
        try await waitUntil("motion after reset") { receiver.sample?.sequence == 3 }
        try require(receiver.movement.speed == 0, "Speed reset retained old velocity")
        sender.send(LinkMessage(kind: .calibrate))
        try await waitUntil("calibration applied") { abs(receiver.orientation.rotation.real - 1) < 0.0001 && !receiver.movement.isAvailable }
        sender.send(LinkMessage(kind: .paused))
        try await waitUntil("pause applied") { receiver.isPaused }
        sample.sequence = 4; sample.timestamp += 1.0 / 60
        sample.acceleration = .zero
        sample.attitude = MotionQuaternion(simd_quatf(angle: 1.2, axis: [1, 0, 0]))
        sender.send(LinkMessage(kind: .motion, sample: sample))
        try await waitUntil("resume received") { receiver.sample?.sequence == 4 }
        try require(abs(receiver.orientation.rotation.real - 1) < 0.0001, "Resume did not establish a fresh neutral pose")
        try require(receiver.movement.speed == 0, "Resume retained old speed")
        for sequence in 5...45 {
            sample.sequence = UInt64(sequence); sample.timestamp += 1.0 / 60
            sender.send(LinkMessage(kind: .motion, sample: sample))
            try await waitUntil("steady hold received") { receiver.sample?.sequence == UInt64(sequence) }
        }
        try require(receiver.neutralCheck.isReady, "An upright steady hold did not enable confirmation")
        try require(!receiver.isNeutralConfirmed, "Steady readings bypassed explicit user confirmation")
        sender.send(LinkMessage(kind: .calibrate))
        try await waitUntil("remote calibration applied") { !receiver.movement.isAvailable }
        try require(!receiver.isNeutralConfirmed, "Remote calibration bypassed the natural-position prompt")
        receiver.confirmNeutralPosition()
        try require(receiver.isNeutralConfirmed, "User confirmation did not activate sword control")
        try require(abs(receiver.orientation.rotation.real - 1) < 0.0001, "Confirmation did not center the sword")
        sample.acceleration = MotionVector(x: 0.3, y: 0, z: 0)
        for sequence in 46...75 {
            sample.sequence = UInt64(sequence); sample.timestamp += 1.0 / 60
            sender.send(LinkMessage(kind: .motion, sample: sample))
            try await waitUntil("hand translation received") { receiver.sample?.sequence == UInt64(sequence) }
        }
        try require(receiver.swordDisplacement.x > 0.3, "Phone movement did not translate the sword grip")
        sample.acceleration = .zero
        sample.attitude = MotionQuaternion(simd_quatf(angle: 0.4, axis: [1, 0, 0]))
        let revisionBeforeCenter = receiver.poseRevision
        for sequence in 76...255 {
            sample.sequence = UInt64(sequence); sample.timestamp += 1.0 / 60
            sender.send(LinkMessage(kind: .motion, sample: sample))
            try await waitUntil("steady handle received") { receiver.sample?.sequence == UInt64(sequence) }
        }
        try require(receiver.isSwordRecentering && receiver.swordDisplacement == .zero, "Steady hold did not recenter the grip")
        let preserved = MotionQuaternion(simd_quatf(angle: -0.8, axis: [1, 0, 0]))
        try require(abs(simd_dot(receiver.orientation.rotation.vector, preserved.rotation.vector)) > 0.9999, "Auto recenter changed the blade angle")
        try require(receiver.isNeutralConfirmed, "Auto recenter unnecessarily reset neutral confirmation")
        try require(receiver.poseRevision > revisionBeforeCenter, "Auto recenter did not clear the collision sweep")
        receiver.resetNeutralPosition()
        try require(receiver.swordDisplacement == .zero, "Neutral reset did not recenter the grip")
        try require(!receiver.isNeutralConfirmed && !receiver.neutralCheck.isReady, "Neutral reset retained readiness")
        receiver.confirmNeutralPosition()
        try require(!receiver.isNeutralConfirmed, "Confirmation bypassed a fresh steady hold")
        sample.sequence = 3 // Old frames cannot overwrite current motion.
        sender.send(LinkMessage(kind: .motion, sample: sample))
        sender.send(LinkMessage(kind: .paused)) // Ordered barrier on the TCP stream.
        try await waitUntil("ordered barrier received") { receiver.isPaused }
        try require(receiver.sample?.sequence == 255, "An old sequence overwrote current motion")
        sample.sequence = 256; sample.attitude = MotionQuaternion(x: 0, y: 0, z: 0, w: 0)
        sender.send(LinkMessage(kind: .motion, sample: sample))
        try await waitUntil("invalid sample disconnect") { log.closed && receiver.deviceName == nil }
        try require(!receiver.isNeutralConfirmed, "Disconnection retained neutral confirmation")
        try require(receiver.sample == nil, "Disconnected readings were not cleared")
        try require(!receiver.movement.isAvailable && receiver.movement.speed == 0, "Disconnected speed was not cleared")
        try require(receiver.pairingCode != pairedCode, "Pairing code did not rotate")
        print("PASS: incorrect code, pairing, one-phone limit, motion vectors, speed reset, calibration, pause/resume, explicit neutral confirmation/reset, 3D grip translation, steady recenter with angle preserved, sequence ordering, invalid-sample disconnect.")
    }
}

@MainActor final class MessageLog {
    var messages: [LinkMessage] = []
    var closed = false
}
