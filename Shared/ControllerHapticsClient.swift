import Foundation
import Observation

/// A game owns returned playback IDs and uses them to adjust or cancel effects.
/// A returned ID means the command was sent; hapticResponse reports acceptance
/// and completion separately. It does not assert that the user physically felt it.
@MainActor @Observable
final class ControllerHaptics {
    private(set) var capabilities: HapticCapabilities?
    private(set) var lastResponse: HapticResponse?
    private(set) var activePlayers: Set<UUID> = []
    var isAvailable: Bool { capabilities?.isAvailable == true && transmit != nil }
    @ObservationIgnored var onResponse: ((HapticResponse) -> Void)?
    @ObservationIgnored private var transmit: ((HapticCommand) -> Bool)?
    @ObservationIgnored private var gate = HapticCommandGate()
    @ObservationIgnored private var pending: [UUID: (HapticCommand, Task<Void, Never>)] = [:]

    func connect(capabilities: HapticCapabilities?, transmit: @escaping (HapticCommand) -> Bool) {
        disconnect(); self.transmit = transmit; setCapabilities(capabilities)
    }
    func setCapabilities(_ value: HapticCapabilities?) {
        capabilities = value?.isValid == true ? value : nil
    }
    func disconnect() {
        for (_, task) in pending.values { task.cancel() }
        pending.removeAll(); activePlayers.removeAll(); capabilities = nil; transmit = nil; gate.reset(); lastResponse = nil
    }

    @discardableResult func play(_ pattern: HapticPattern, channel: String = "main", delay: Double = 0,
                                 loop: Bool = false, lifetime: Double = 5,
                                 parameters: HapticParameters = HapticParameters()) -> UUID? {
        let playback = HapticPlayback(channel: channel, pattern: pattern, delay: delay, loop: loop, lifetime: lifetime, parameters: parameters)
        let command = HapticCommand(action: .play, playback: playback)
        guard playback.isValid else {
            report(HapticResponse(requestID: command.requestID, playbackID: playback.id, status: .rejected, reason: .invalidCommand)); return nil
        }
        guard capabilities?.supports(playback) == true else {
            report(HapticResponse(requestID: command.requestID, playbackID: playback.id, status: .rejected, reason: .unsupported)); return nil
        }
        guard activePlayers.count < (capabilities?.maximumConcurrentPlayers ?? 0) else {
            report(HapticResponse(requestID: command.requestID, playbackID: playback.id, status: .rejected, reason: .playerLimit)); return nil
        }
        guard send(command) else { return nil }
        activePlayers.insert(playback.id)
        return playback.id
    }
    @discardableResult func update(_ id: UUID, parameters: HapticParameters) -> Bool {
        guard capabilities?.supportsLiveUpdates == true else { return false }
        return send(HapticCommand(action: .update, playbackID: id, parameters: parameters))
    }
    @discardableResult func stop(_ id: UUID) -> Bool {
        guard activePlayers.contains(id) else { return false }
        return send(HapticCommand(action: .stop, playbackID: id))
    }
    @discardableResult func stopAll() -> Bool { send(HapticCommand(action: .stopAll)) }

    func receive(_ response: HapticResponse) {
        guard response.isValid else { return }
        // Only responses for our requests or the lifecycle of our active players
        // may change state. Late responses from a disconnected peer are discarded.
        guard pending[response.requestID] != nil || response.playbackID.map({ activePlayers.contains($0) }) == true else { return }
        let request = pending.removeValue(forKey: response.requestID)
        request?.1.cancel()
        let ended = [.stopped, .completed, .expired, .interrupted, .failed].contains(response.status)
            || response.status == .rejected && request?.0.action == .play
        if ended, let id = response.playbackID { activePlayers.remove(id) }
        if response.status == .stopped && request?.0.action == .stopAll { activePlayers.removeAll() }
        report(response)
    }
    private func send(_ command: HapticCommand) -> Bool {
        let stopping = command.action == .stop || command.action == .stopAll
        if stopping && pending.values.contains(where: { $0.0.action == command.action && $0.0.playbackID == command.playbackID }) { return true }
        if let reason = gate.check(command, time: ProcessInfo.processInfo.systemUptime) {
            report(HapticResponse(requestID: command.requestID, playbackID: command.playback?.id ?? command.playbackID, status: .rejected, reason: reason)); return false
        }
        // Reserve nine slots for stop-all plus the eight active player stops.
        guard pending.count < (stopping ? 32 : 23) else {
            report(HapticResponse(requestID: command.requestID, playbackID: command.playback?.id ?? command.playbackID, status: .rejected, reason: .rateLimited)); return false
        }
        guard let transmit, transmit(command) else {
            report(HapticResponse(requestID: command.requestID, playbackID: command.playback?.id ?? command.playbackID, status: .failed, reason: .disconnected)); return false
        }
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.pending.removeValue(forKey: command.requestID) != nil else { return }
            if command.action == .play, let id = command.playback?.id { self.activePlayers.remove(id) }
            self.report(HapticResponse(requestID: command.requestID, playbackID: command.playback?.id ?? command.playbackID, status: .failed, reason: .timeout))
        }
        pending[command.requestID] = (command, timeout)
        return true
    }
    private func report(_ response: HapticResponse) { lastResponse = response; onResponse?(response) }
}
