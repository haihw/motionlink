import Foundation
import Network
import simd
import Testing
@testable import MotionLinkCore

private func fixture(sequence: UInt64 = 1) -> MotionSample {
    MotionSample(sequence: sequence, timestamp: 12.5, attitude: .identity,
                 rotationRate: MotionVector(x: 0.1, y: -0.2, z: 0.3),
                 acceleration: .zero, gravity: MotionVector(x: 0, y: -1, z: 0))
}

@Test("TCP frames survive arbitrary splits and multiple frames in one read")
func framing() throws {
    let first = try FrameDecoder.encode(LinkMessage(kind: .hello, code: "123456", deviceName: "Test iPhone"))
    let second = try FrameDecoder.encode(LinkMessage(kind: .motion, sample: fixture()))
    let combined = first + second
    for split in 0...combined.count {
        var decoder = FrameDecoder()
        let messages = try decoder.append(Data(combined.prefix(split))) + decoder.append(Data(combined.dropFirst(split)))
        #expect(messages.count == 2)
        #expect(messages.first?.code == "123456")
        #expect(messages.last?.sample?.sequence == 1)
    }
}

@Test("Oversized and zero-length packets are rejected before decoding", arguments: [Data([0, 0, 0, 0]), Data([0, 0, 64, 1]), Data([255, 255, 255, 255])])
func invalidFrameLengths(bytes: Data) {
    var decoder = FrameDecoder()
    #expect(throws: FrameDecoder.FrameError.self) { try decoder.append(bytes) }
}

@Test("Incompatible protocol versions and corrupt JSON are rejected")
func invalidMessages() throws {
    var message = LinkMessage(kind: .hello); message.version = LinkMessage.protocolVersion + 1
    var decoder = FrameDecoder()
    #expect(throws: FrameDecoder.FrameError.self) { try decoder.append(FrameDecoder.encode(message)) }
    var corrupt = FrameDecoder()
    #expect(throws: (any Error).self) { try corrupt.append(Data([0, 0, 0, 1, 120])) }
}

@Test("Calibration preserves rotation in device axes from a nontrivial neutral pose")
func calibration() {
    let baseline = simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
    let movement = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
    let result = MotionQuaternion(baseline * movement).relative(to: MotionQuaternion(baseline)).rotation
    #expect(abs(simd_dot(result.vector, movement.vector)) > 0.99999)
    let neutral = MotionQuaternion(baseline).relative(to: MotionQuaternion(baseline))
    #expect(abs(neutral.rotation.real - 1) < 0.00001)
    let rotatedUp = result.act(SIMD3<Float>(0, 1, 0))
    #expect(simd_distance(rotatedUp, SIMD3<Float>(0, 0, 1)) < 0.00001)
}

@Test("Invalid sensor samples cannot enter the renderer")
func sampleValidation() {
    var sample = fixture()
    #expect(sample.isValid)
    sample.attitude.w = 0
    #expect(!sample.isValid)
    sample = fixture(); sample.timestamp = .infinity
    #expect(!sample.isValid)
    sample = fixture(); sample.acceleration.x = .nan
    #expect(!sample.isValid)
    sample = fixture(); sample.rotationRate.z = 20_000
    #expect(!sample.isValid)
}

@Test("A real local TCP connection exchanges framed motion", .timeLimit(.minutes(1)))
@MainActor
func localConnection() async throws {
    let listener = try NWListener(using: LinkSettings.parameters())
    let holder = ConnectionHolder()
    listener.newConnectionHandler = { connection in
        Task { @MainActor in
            let channel = LinkConnection(connection)
            holder.connection = channel
            channel.onMessage = { [weak channel] message in channel?.send(message) }
            channel.start()
        }
    }
    defer {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        holder.connection?.close()
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        listener.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }
    let port = try #require(listener.port)
    let sender = LinkConnection(NWConnection(host: "127.0.0.1", port: port, using: LinkSettings.parameters()))
    defer { sender.close() }
    let response: LinkMessage = try await withCheckedThrowingContinuation { continuation in
        var finished = false
        sender.onReady = { sender.send(LinkMessage(kind: .motion, sample: fixture(sequence: 42))) }
        sender.onMessage = { message in
            guard !finished else { return }
            finished = true
            continuation.resume(returning: message)
        }
        sender.onClose = { reason in
            guard !finished else { return }
            finished = true
            continuation.resume(throwing: NSError(domain: "MotionLink", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]))
        }
        sender.start()
    }
    #expect(response.kind == .motion)
    #expect(response.sample?.sequence == 42)
    #expect(response.sample?.isValid == true)
}

@MainActor private final class ConnectionHolder { var connection: LinkConnection? }
