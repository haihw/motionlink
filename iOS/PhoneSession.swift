import CoreMotion
import Foundation
import Network
import Observation
import UIKit

struct NearbyMac: Identifiable {
    let endpoint: NWEndpoint
    let name: String
    var id: String { String(describing: endpoint) }
}

@MainActor @Observable
final class PhoneSession {
    var nearbyMacs: [NearbyMac] = []
    var status = "Looking for your Mac"
    var connectedName: String?
    var isConnecting = false
    var isStreaming = false
    var sample: MotionSample?
    var movement = MotionEstimate.unavailable
    var errorMessage: String?
    var pairingCode = ""
    var hapticsEnabled = true
    var supportsHaptics: Bool { haptics.capabilities.supportsHaptics }
    var hasMotion: Bool { motion.isDeviceMotionAvailable }

    @ObservationIgnored private var motionTracker = LinearMotionTracker()
    @ObservationIgnored private var reference: MotionQuaternion?
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let haptics = PhoneHaptics()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var link: LinkConnection?
    @ObservationIgnored private var motionTask: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var sequence: UInt64 = 0

    func discover() {
        guard browser == nil else { return }
        errorMessage = nil
        status = "Looking for your Mac"
        let browser = NWBrowser(for: .bonjour(type: LinkSettings.serviceType, domain: nil), using: LinkSettings.parameters())
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browser === browser else { return }
                self.nearbyMacs = results.compactMap { result in
                    if case let .service(name, _, _, _) = result.endpoint {
                        return NearbyMac(endpoint: result.endpoint, name: name)
                    }
                    return nil
                }.sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.browser === browser else { return }
                if case .failed(let error) = state {
                    self.errorMessage = "Discovery failed: \(error.localizedDescription). Check Local Network access in Settings."
                    self.stopDiscovery()
                }
                if case .waiting(let error) = state { self.errorMessage = error.localizedDescription }
            }
        }
        browser.start(queue: .main)
    }

    func connect(to mac: NearbyMac) {
        guard pairingCode.count == 6, pairingCode.allSatisfy(\.isNumber), link == nil else { return }
        errorMessage = nil
        isConnecting = true
        status = "Connecting to \(mac.name)…"
        let channel = LinkConnection(NWConnection(to: mac.endpoint, using: LinkSettings.parameters()))
        link = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel, self.link === channel else { return }
            channel.send(LinkMessage(kind: .hello, code: self.pairingCode, deviceName: UIDevice.current.name, hapticCapabilities: self.haptics.capabilities))
        }
        haptics.onResponse = { [weak self, weak channel] response in
            guard let self, let channel, self.link === channel, self.connectedName != nil else { return }
            channel.send(LinkMessage(kind: .hapticResponse, hapticResponse: response))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel, self.link === channel else { return }
            switch message.kind {
            case .accepted:
                guard self.isConnecting, self.connectedName == nil else { return }
                self.timeout?.cancel()
                self.isConnecting = false
                self.connectedName = mac.name
                self.status = "Connected"
                self.startMotion()
                self.publishHapticCapabilities()
            case .hapticCommand:
                guard self.connectedName != nil, let command = message.hapticCommand else { return }
                self.haptics.handle(command)
            case .calibrate:
                self.reference = self.sample?.attitude
                self.resetMovement()
            case .resetMovement: self.resetMovement()
            case .rejected:
                let reason = message.reason ?? "Pairing rejected"
                channel.close(reason: reason)
            default: break
            }
        }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, self.link === channel else { return }
            self.stopMotion()
            self.haptics.disconnect()
            self.link = nil
            self.connectedName = nil
            self.sample = nil
            self.isConnecting = false
            self.timeout?.cancel()
            self.status = "Disconnected"
            self.errorMessage = reason
        }
        timeout = Task { [weak self, weak channel] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, let channel, self.link === channel, self.isConnecting else { return }
            channel.close(reason: "Pairing timed out. Check the code and your network, then try again.")
        }
        channel.start()
    }

    func toggleStreaming() {
        if isStreaming {
            stopMotion()
            status = "Streaming paused"
            link?.send(LinkMessage(kind: .paused))
        } else { startMotion() }
    }

    func setHapticsEnabled(_ value: Bool) {
        hapticsEnabled = value
        haptics.setEnabled(value && connectedName != nil && isStreaming)
        publishHapticCapabilities()
    }

    private func publishHapticCapabilities() {
        guard connectedName != nil else { return }
        link?.send(LinkMessage(kind: .hapticCapabilities, hapticCapabilities: haptics.capabilities))
    }

    func calibrate() {
        reference = sample?.attitude
        resetMovement()
        link?.send(LinkMessage(kind: .calibrate))
    }

    func resetMovement(notifyMac: Bool = false) {
        motionTracker.reset()
        movement = .unavailable
        if notifyMac { link?.send(LinkMessage(kind: .resetMovement)) }
    }

    func disconnect() {
        timeout?.cancel()
        stopMotion()
        haptics.disconnect()
        link?.close(reason: "Disconnected")
        link = nil
        connectedName = nil
        sample = nil
        isConnecting = false
        errorMessage = nil
        status = "Looking for your Mac"
    }

    func suspend() {
        disconnect()
        stopDiscovery()
    }

    private func stopDiscovery() {
        let oldBrowser = browser
        browser = nil
        oldBrowser?.stateUpdateHandler = nil
        oldBrowser?.browseResultsChangedHandler = nil
        oldBrowser?.cancel()
        nearbyMacs = []
    }

    private func startMotion() {
        guard connectedName != nil, !isStreaming else { return }
        guard hasMotion else {
            errorMessage = "Motion sensors are unavailable. Run this app on a physical iPhone."
            link?.send(LinkMessage(kind: .paused))
            return
        }
        reference = nil
        resetMovement()
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        isStreaming = true
        haptics.setEnabled(hapticsEnabled)
        publishHapticCapabilities()
        status = "Streaming live motion"
        UIApplication.shared.isIdleTimerDisabled = true
        motionTask = Task { [weak self] in
            var lastTimestamp = -1.0
            let started = Date()
            while !Task.isCancelled {
                guard let self, self.isStreaming else { break }
                if let data = self.motion.deviceMotion, data.timestamp > lastTimestamp {
                    lastTimestamp = data.timestamp
                    self.sequence &+= 1
                    let q = data.attitude.quaternion
                    let value = MotionSample(
                        sequence: self.sequence, timestamp: data.timestamp,
                        attitude: MotionQuaternion(x: q.x, y: q.y, z: q.z, w: q.w),
                        rotationRate: MotionVector(x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z),
                        acceleration: MotionVector(x: data.userAcceleration.x, y: data.userAcceleration.y, z: data.userAcceleration.z),
                        gravity: MotionVector(x: data.gravity.x, y: data.gravity.y, z: data.gravity.z))
                    self.sample = value
                    if self.reference == nil { self.reference = value.attitude }
                    self.movement = self.motionTracker.update(value, orientation: value.attitude.relative(to: self.reference ?? .identity))
                    self.link?.send(LinkMessage(kind: .motion, sample: value))
                }
                if lastTimestamp < 0 && Date().timeIntervalSince(started) > 5 {
                    self.stopMotion()
                    self.errorMessage = "No motion data available. Check motion access in Settings and try resuming."
                    self.status = "Motion unavailable"
                    self.link?.send(LinkMessage(kind: .paused))
                    break
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
    }

    private func stopMotion() {
        motionTask?.cancel(); motionTask = nil
        motion.stopDeviceMotionUpdates()
        isStreaming = false
        haptics.setEnabled(false)
        publishHapticCapabilities()
        resetMovement()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
