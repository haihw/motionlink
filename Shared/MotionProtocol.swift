import Foundation
import simd

struct MotionQuaternion: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = Self(x: 0, y: 0, z: 0, w: 1)
    var isValid: Bool {
        let values = [x, y, z, w]
        let length = values.reduce(0) { $0 + $1 * $1 }
        return values.allSatisfy(\.isFinite) && (0.9...1.1).contains(length)
    }
    var rotation: simd_quatf {
        simd_normalize(simd_quatf(ix: Float(x), iy: Float(y), iz: Float(z), r: Float(w)))
    }
    init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }
    init(_ rotation: simd_quatf) {
        let q = simd_normalize(rotation)
        self.init(x: Double(q.imag.x), y: Double(q.imag.y), z: Double(q.imag.z), w: Double(q.real))
    }
    /// The neutral pose maps the current device axes to the model axes.
    func relative(to reference: Self) -> Self {
        Self(reference.rotation.inverse * rotation)
    }
}

struct MotionVector: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
    static let zero = Self(x: 0, y: 0, z: 0)
    var isValid: Bool { [x, y, z].allSatisfy { $0.isFinite && abs($0) < 10_000 } }
    var magnitude: Double { sqrt(x * x + y * y + z * z) }
}

struct MotionSample: Codable, Sendable {
    var sequence: UInt64
    var timestamp: Double // Device uptime; never compare clocks across devices.
    var attitude: MotionQuaternion
    var rotationRate: MotionVector // radians / second
    var acceleration: MotionVector // g, excluding gravity
    var gravity: MotionVector // g
    var isValid: Bool {
        timestamp.isFinite && timestamp >= 0 && attitude.isValid && rotationRate.isValid
            && acceleration.isValid && gravity.isValid
    }
}

struct LinkMessage: Codable, Sendable {
    static let protocolVersion = 2
    enum Kind: String, Codable, Sendable { case hello, accepted, rejected, motion, paused, calibrate, resetMovement }
    var version = protocolVersion
    var kind: Kind
    var code: String?
    var deviceName: String?
    var reason: String?
    var sample: MotionSample?
}

/// TCP is a byte stream: packets may be split or coalesced arbitrarily.
struct FrameDecoder {
    static let maximumPayload = 16_384
    private var buffer = Data()

    mutating func append(_ bytes: Data) throws -> [LinkMessage] {
        buffer.append(bytes)
        var messages: [LinkMessage] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard size > 0 && size <= Self.maximumPayload else { throw FrameError.invalidLength }
            guard buffer.count >= 4 + size else { break }
            let payload = Data(buffer.dropFirst(4).prefix(size))
            let message = try JSONDecoder().decode(LinkMessage.self, from: payload)
            guard message.version == LinkMessage.protocolVersion else { throw FrameError.unsupportedVersion }
            messages.append(message)
            buffer.removeFirst(4 + size)
        }
        return messages
    }
    static func encode(_ message: LinkMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard !payload.isEmpty && payload.count <= maximumPayload else { throw FrameError.invalidLength }
        let count = UInt32(payload.count)
        var data = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                         UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(payload)
        return data
    }
    enum FrameError: Error { case invalidLength, unsupportedVersion }
}
