import Foundation

/// Platform-neutral controller feedback. Times are seconds relative to a pattern
/// or receipt of a command; clocks are never compared across the network.
struct HapticEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case transient, continuous }
    var kind: Kind
    var time = 0.0
    var duration = 0.0
    var intensity: Float = 1
    var sharpness: Float = 0.5
    var isValid: Bool {
        time.isFinite && (0...10).contains(time) && intensity.isFinite && (0...1).contains(intensity)
            && sharpness.isFinite && (0...1).contains(sharpness) && duration.isFinite
            && (kind == .transient ? duration == 0 : duration > 0 && time + duration <= 10)
    }
    var endTime: Double { time + (kind == .transient ? 0.1 : duration) }
}

struct HapticCurve: Codable, Sendable, Equatable {
    enum Parameter: String, Codable, Sendable {
        case intensityScale // 0...1, multiplying each event's intensity
        case sharpnessOffset // -1...1, added to each event's sharpness
    }
    struct Point: Codable, Sendable, Equatable {
        var time: Double
        var value: Float
    }
    var parameter: Parameter
    var points: [Point]
    var isValid: Bool {
        guard (2...16).contains(points.count) else { return false }
        var previous = -1.0
        for point in points {
            guard point.time.isFinite, (0...10).contains(point.time), point.time > previous,
                  point.value.isFinite, (parameter == .intensityScale ? 0...1 : -1...1).contains(point.value) else { return false }
            previous = point.time
        }
        return true
    }
}

struct HapticPattern: Codable, Sendable, Equatable {
    var events: [HapticEvent]
    var curves: [HapticCurve] = []
    var duration: Double { max(events.map(\.endTime).max() ?? 0, curves.compactMap { $0.points.last?.time }.max() ?? 0) }
    var isValid: Bool {
        !events.isEmpty && events.count <= 64 && events.allSatisfy(\.isValid)
            && curves.count <= 4 && curves.allSatisfy(\.isValid)
            && Set(curves.map(\.parameter)).count == curves.count && duration <= 10
    }
    static func impact(intensity: Float = 0.8, sharpness: Float = 0.6) -> Self {
        Self(events: [HapticEvent(kind: .transient, intensity: intensity, sharpness: sharpness)])
    }
    static func rumble(duration: Double = 1, intensity: Float = 0.5) -> Self {
        Self(events: [HapticEvent(kind: .continuous, duration: duration, intensity: intensity, sharpness: 0.1)])
    }
    static let success = Self(events: [
        HapticEvent(kind: .transient, intensity: 0.45, sharpness: 0.4),
        HapticEvent(kind: .transient, time: 0.12, intensity: 0.65, sharpness: 0.5),
        HapticEvent(kind: .transient, time: 0.27, intensity: 0.95, sharpness: 0.7)
    ])
    static let failure = Self(events: [
        HapticEvent(kind: .continuous, duration: 0.18, intensity: 0.7, sharpness: 0.1),
        HapticEvent(kind: .transient, time: 0.28, intensity: 0.8, sharpness: 0.2)
    ])
}

struct HapticParameters: Codable, Sendable, Equatable {
    var intensityScale: Float?
    var sharpnessOffset: Float?
    var playbackRate: Float?
    var hasChanges: Bool { intensityScale != nil || sharpnessOffset != nil || playbackRate != nil }
    var isValid: Bool {
        (intensityScale.map { $0.isFinite && (0...1).contains($0) } ?? true)
            && (sharpnessOffset.map { $0.isFinite && (-1...1).contains($0) } ?? true)
            && (playbackRate.map { $0.isFinite && (0.5...2).contains($0) } ?? true)
    }
    func conflicts(with pattern: HapticPattern) -> Bool {
        pattern.curves.contains { ($0.parameter == .intensityScale && intensityScale != nil)
            || ($0.parameter == .sharpnessOffset && sharpnessOffset != nil) }
    }
}

struct HapticPlayback: Codable, Sendable, Equatable {
    var id = UUID()
    var channel = "main"
    var pattern: HapticPattern
    var delay = 0.0
    var loop = false
    /// A receiver-enforced wall-clock lease, including delayed start. Loops never
    /// run forever after a lost stop command. Send a fresh play for a new lease.
    var lifetime = 5.0
    var parameters = HapticParameters()
    var isValid: Bool {
        !channel.isEmpty && channel.utf8.count <= 32 && pattern.isValid && parameters.isValid && !parameters.conflicts(with: pattern)
            && delay.isFinite && (0...2).contains(delay) && lifetime.isFinite
            && (0.1...30).contains(lifetime) && delay < lifetime
            && (loop || delay + pattern.duration / Double(parameters.playbackRate ?? 1) <= lifetime)
    }
}

struct HapticCommand: Codable, Sendable, Equatable {
    enum Action: String, Codable, Sendable { case play, update, stop, stopAll }
    var requestID = UUID()
    var action: Action
    var playback: HapticPlayback?
    var playbackID: UUID?
    var parameters: HapticParameters?
    var isValid: Bool {
        switch action {
        case .play: playback?.isValid == true && playbackID == nil && parameters == nil
        case .update: playback == nil && playbackID != nil && parameters?.isValid == true && parameters?.hasChanges == true
        case .stop: playback == nil && playbackID != nil && parameters == nil
        case .stopAll: playback == nil && playbackID == nil && parameters == nil
        }
    }
}

struct HapticCapabilities: Codable, Sendable, Equatable {
    var supportsHaptics: Bool
    var isEnabled = true
    var channels = ["main"]
    var supportsCurves = true
    var supportsLooping = true
    var supportsLiveUpdates = true
    var maximumEvents = 64
    var maximumPatternDuration = 10.0
    var maximumLifetime = 30.0
    var maximumConcurrentPlayers = 8
    var isAvailable: Bool { supportsHaptics && isEnabled && channels.contains("main") }
    var isValid: Bool {
        channels.count <= 8 && Set(channels).count == channels.count && channels.allSatisfy { !$0.isEmpty && $0.utf8.count <= 32 }
            && (1...64).contains(maximumEvents) && maximumPatternDuration.isFinite && (0.1...10).contains(maximumPatternDuration)
            && maximumLifetime.isFinite && (0.1...30).contains(maximumLifetime) && (1...8).contains(maximumConcurrentPlayers)
    }
    func supports(_ playback: HapticPlayback) -> Bool {
        isAvailable && playback.isValid && channels.contains(playback.channel)
            && playback.pattern.events.count <= maximumEvents && playback.pattern.duration <= maximumPatternDuration
            && playback.lifetime <= maximumLifetime && (!playback.loop || supportsLooping)
            && (playback.pattern.curves.isEmpty || supportsCurves)
    }
}

struct HapticResponse: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable { case accepted, updated, stopped, completed, expired, interrupted, rejected, failed }
    enum Reason: String, Codable, Sendable { case unsupported, disabled, invalidCommand, rateLimited, duplicateRequest, playerLimit, notFound, engineError, timeout, disconnected }
    var requestID: UUID
    var playbackID: UUID?
    var status: Status
    var reason: Reason?
    var detail: String?
    var isTerminal: Bool { status != .accepted && status != .updated }
    var isValid: Bool { detail.map { $0.utf8.count <= 256 } ?? true }
}

/// Bound work and replay history. Stop commands bypass the rate budget so a busy
/// feedback stream cannot prevent the controller from being silenced.
struct HapticCommandGate: Sendable {
    private var recent: [UUID] = []
    private var tokens = 20.0
    private var lastTime: Double?
    mutating func reset() { self = Self() }
    mutating func check(_ command: HapticCommand, time: Double) -> HapticResponse.Reason? {
        guard command.isValid, time.isFinite else { return .invalidCommand }
        guard !recent.contains(command.requestID) else { return .duplicateRequest }
        recent.append(command.requestID)
        if recent.count > 128 { recent.removeFirst() }
        if let lastTime { tokens = min(20, tokens + max(0, time - lastTime) * 60) }
        lastTime = time
        if command.action == .stop || command.action == .stopAll { return nil }
        guard tokens >= 1 else { return .rateLimited }
        tokens -= 1
        return nil
    }
}
