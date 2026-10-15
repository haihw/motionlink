import CoreHaptics
import Foundation

/// Hardware adapter for the generic controller protocol. Every effect has a
/// bounded lease and is stopped on pause, disconnect, background, or interruption.
@MainActor
final class PhoneHaptics {
    private struct Playing {
        let requestID: UUID
        let token: UUID
        let pattern: HapticPattern
        let player: any CHHapticAdvancedPatternPlayer
        let expiry: Task<Void, Never>
    }
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var enabled = false
    private var engine: CHHapticEngine?
    private var engineGeneration = UUID()
    private var players: [UUID: Playing] = [:]
    private var gate = HapticCommandGate()
    var onResponse: ((HapticResponse) -> Void)?
    var capabilities: HapticCapabilities { HapticCapabilities(supportsHaptics: supported, isEnabled: enabled) }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { interruptAll() }
    }
    func disconnect() {
        enabled = false; interruptAll(); gate.reset()
        engine?.stoppedHandler = { _ in }; engine?.resetHandler = {}
        engine?.stop(completionHandler: nil); engine = nil; engineGeneration = UUID()
    }
    func handle(_ command: HapticCommand) {
        if let reason = gate.check(command, time: ProcessInfo.processInfo.systemUptime) { reject(command, reason); return }
        if command.action == .stopAll {
            for id in Array(players.keys) { finish(id, status: .stopped, stop: true) }
            reply(command, status: .stopped); return
        }
        if command.action == .stop, let id = command.playbackID {
            guard players[id] != nil else { reject(command, .notFound); return }
            finish(id, status: .stopped, stop: true); reply(command, status: .stopped); return
        }
        guard supported else { reject(command, .unsupported); return }
        guard enabled else { reject(command, .disabled); return }
        do {
            switch command.action {
            case .play:
                guard let playback = command.playback, capabilities.supports(playback) else { reject(command, .unsupported); return }
                guard players.count < capabilities.maximumConcurrentPlayers, players[playback.id] == nil else { reject(command, .playerLimit); return }
                let engine = try prepareEngine()
                let pattern = try Self.makeNativePattern(playback.pattern, padForLoop: playback.loop)
                let player = try engine.makeAdvancedPlayer(with: pattern)
                player.loopEnabled = playback.loop
                if playback.loop { player.loopEnd = pattern.duration }
                player.playbackRate = playback.parameters.playbackRate ?? 1
                let token = UUID(), id = playback.id
                player.completionHandler = { [weak self] error in
                    let failed = error != nil
                    Task { @MainActor in
                        guard let self, self.players[id]?.token == token else { return }
                        self.finish(id, status: failed ? .failed : .completed, stop: false)
                    }
                }
                let expiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(playback.lifetime)) } catch { return }
                    guard let self, self.players[id]?.token == token else { return }
                    self.finish(id, status: .expired, stop: true)
                }
                players[id] = Playing(requestID: command.requestID, token: token, pattern: playback.pattern, player: player, expiry: expiry)
                do {
                    let start = playback.delay > 0 ? engine.currentTime + playback.delay : CHHapticTimeImmediate
                    try player.start(atTime: start)
                    try apply(playback.parameters, to: player, at: start)
                    reply(command, status: .accepted)
                } catch {
                    finish(id, status: .failed, stop: true)
                }
            case .update:
                guard let id = command.playbackID, let entry = players[id], let parameters = command.parameters else { reject(command, .notFound); return }
                guard !parameters.conflicts(with: entry.pattern) else {
                    reject(command, .invalidCommand, detail: "A scripted curve owns that control. Use a separate live-controlled player."); return
                }
                try apply(parameters, to: entry.player, at: CHHapticTimeImmediate)
                reply(command, status: .updated)
            case .stop, .stopAll: break
            }
        } catch { reject(command, .engineError, detail: String(decoding: error.localizedDescription.utf8.prefix(240), as: UTF8.self)) }
    }

    private func prepareEngine() throws -> CHHapticEngine {
        if let engine { try engine.start(); return engine }
        let newEngine = try CHHapticEngine()
        newEngine.playsHapticsOnly = true; newEngine.isAutoShutdownEnabled = true
        let generation = UUID(); engineGeneration = generation
        newEngine.stoppedHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engineGeneration == generation else { return }
                self.interruptAll()
            }
        }
        newEngine.resetHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.engineGeneration == generation else { return }
                self.interruptAll(); self.engine = nil; self.engineGeneration = UUID()
            }
        }
        try newEngine.start(); engine = newEngine
        return newEngine
    }
    static func makeNativePattern(_ pattern: HapticPattern, padForLoop: Bool) throws -> CHHapticPattern {
        var events = pattern.events.map { event in
            CHHapticEvent(eventType: event.kind == .transient ? .hapticTransient : .hapticContinuous,
                          parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: event.intensity),
                                       CHHapticEventParameter(parameterID: .hapticSharpness, value: event.sharpness)],
                          relativeTime: event.time, duration: event.duration)
        }
        // A transient at t=0 can have a native pattern duration of zero. A silent
        // tail gives pulse loops a real cycle without adding another sensation.
        if padForLoop {
            events.append(CHHapticEvent(eventType: .hapticContinuous,
                                        parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 0)],
                                        relativeTime: max(0, pattern.duration - 0.01), duration: 0.01))
        }
        let curves = pattern.curves.map { curve in
            CHHapticParameterCurve(parameterID: curve.parameter == .intensityScale ? .hapticIntensityControl : .hapticSharpnessControl,
                                  controlPoints: curve.points.map { CHHapticParameterCurve.ControlPoint(relativeTime: $0.time, value: $0.value) }, relativeTime: 0)
        }
        return try CHHapticPattern(events: events, parameterCurves: curves)
    }
    private func apply(_ parameters: HapticParameters, to player: any CHHapticAdvancedPatternPlayer, at time: TimeInterval) throws {
        var changes: [CHHapticDynamicParameter] = []
        if let intensity = parameters.intensityScale { changes.append(CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)) }
        if let sharpness = parameters.sharpnessOffset { changes.append(CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0)) }
        if let rate = parameters.playbackRate { player.playbackRate = rate }
        if !changes.isEmpty { try player.sendParameters(changes, atTime: time) }
    }
    private func finish(_ id: UUID, status: HapticResponse.Status, stop: Bool) {
        guard let entry = players.removeValue(forKey: id) else { return }
        entry.expiry.cancel()
        if stop { try? entry.player.stop(atTime: CHHapticTimeImmediate) }
        onResponse?(HapticResponse(requestID: entry.requestID, playbackID: id, status: status))
    }
    private func interruptAll() {
        for id in Array(players.keys) { finish(id, status: .interrupted, stop: true) }
    }
    private func reply(_ command: HapticCommand, status: HapticResponse.Status) {
        onResponse?(HapticResponse(requestID: command.requestID, playbackID: command.playback?.id ?? command.playbackID, status: status))
    }
    private func reject(_ command: HapticCommand, _ reason: HapticResponse.Reason, detail: String? = nil) {
        onResponse?(HapticResponse(requestID: command.requestID, playbackID: command.playback?.id ?? command.playbackID, status: .rejected, reason: reason, detail: detail))
    }
}
