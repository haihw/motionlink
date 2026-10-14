import Foundation
import Network
import Observation
import simd

@MainActor @Observable
final class MacSession {
    var pairingCode = MacSession.makeCode()
    var deviceName: String?
    var status = "Starting receiver"
    var errorMessage: String?
    var sample: MotionSample?
    var orientation = MotionQuaternion.identity
    var poseRevision = 0
    var isNeutralConfirmed = false
    var neutralCheck = NeutralPoseCheck()
    var movement = MotionEstimate.unavailable
    var swordDisplacement = SIMD3<Float>.zero
    var receivedFPS = 0
    var isListening = false
    var isPaused = false
    var isStale = false
    var isDemo = false
    var macName = Host.current().localizedName ?? "MotionLink Mac"

    @ObservationIgnored private var neutralMonitor = NeutralPoseMonitor()
    @ObservationIgnored private var motionTracker = LinearMotionTracker()
    @ObservationIgnored private var swordTranslation = SwordTranslationTracker()
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var link: LinkConnection?
    @ObservationIgnored private var reference: MotionQuaternion?
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var lastArrival: Date?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var pairTimeout: Task<Void, Never>?
    @ObservationIgnored private var demoTask: Task<Void, Never>?

    var listeningPort: NWEndpoint.Port? { listener?.port }

    private static func makeCode(excluding previous: String? = nil) -> String {
        var code: String
        repeat { code = String(format: "%06d", Int.random(in: 0...999_999)) } while code == previous
        return code
    }

    func start() {
        guard listener == nil else { return }
        errorMessage = nil
        do {
            let listener = try NWListener(using: LinkSettings.parameters())
            self.listener = listener
            listener.service = NWListener.Service(name: macName, type: LinkSettings.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.isListening = true; self.status = "Ready to pair"
                    case .failed(let error):
                        self.stop()
                        self.errorMessage = "Receiver failed: \(error.localizedDescription). Check Local Network access in System Settings."
                    case .waiting(let error): self.errorMessage = error.localizedDescription
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.listener === listener else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.start(queue: .main)
            metricsTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    guard let self else { break }
                    self.receivedFPS = self.frameCount
                    self.frameCount = 0
                    self.isStale = self.deviceName != nil && !self.isPaused
                        && (self.lastArrival.map { Date().timeIntervalSince($0) > 2 } ?? true)
                    if self.isStale {
                        self.status = "Waiting for motion"
                        self.resetMovement()
                        self.resetNeutralPosition()
                    }
                }
            }
        } catch { errorMessage = error.localizedDescription; status = "Receiver unavailable" }
    }

    private func accept(_ connection: NWConnection) {
        // Reserve the receiver while pairing, too: only one phone at a time.
        guard link == nil else { connection.cancel(); return }
        let channel = LinkConnection(connection)
        link = channel
        pairTimeout = Task { [weak self, weak channel] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.link === channel, self.deviceName == nil else { return }
            channel?.close(reason: "Pairing timed out")
        }
        var isRejecting = false
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel, self.link === channel else { return }
            guard !isRejecting else { return }
            if self.deviceName == nil {
                guard message.kind == .hello, message.code == self.pairingCode else {
                    isRejecting = true
                    channel.send(LinkMessage(kind: .rejected, reason: "Incorrect pairing code. Enter the six digits shown on your Mac.")) {
                        channel.close(reason: "Incorrect pairing code")
                    }
                    return
                }
                self.stopDemo()
                self.pairTimeout?.cancel()
                self.reference = nil; self.lastSequence = nil; self.sample = nil
                self.poseRevision += 1
                self.resetNeutralPosition()
                self.resetMovement()
                self.lastArrival = Date()
                self.deviceName = String((message.deviceName ?? "iPhone").prefix(80))
                self.status = "Connected · waiting for motion"
                self.errorMessage = nil
                channel.send(LinkMessage(kind: .accepted))
                return
            }
            switch message.kind {
            case .motion:
                guard let sample = message.sample, sample.isValid else {
                    channel.close(reason: "Invalid motion sample"); return
                }
                guard self.lastSequence.map({ sample.sequence > $0 }) ?? true else { return }
                if self.isPaused { self.reference = nil; self.resetNeutralPosition(); self.resetMovement() }
                self.lastSequence = sample.sequence
                self.lastArrival = Date()
                self.frameCount += 1
                self.isPaused = false; self.isStale = false
                self.status = "Live motion"
                if self.reference == nil { self.reference = sample.attitude }
                self.sample = sample
                self.neutralCheck = self.neutralMonitor.update(sample)
                self.orientation = sample.attitude.relative(to: self.reference ?? .identity)
                self.movement = self.motionTracker.update(sample, orientation: self.orientation)
                if self.isNeutralConfirmed {
                    self.swordDisplacement = self.swordTranslation.update(self.movement, timestamp: sample.timestamp)
                }
            case .paused:
                self.isPaused = true; self.status = "Phone paused"
                self.resetNeutralPosition()
                self.resetMovement()
            case .calibrate: self.calibrate()
            case .resetMovement: self.resetMovement()
            default: break
            }
        }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, self.link === channel else { return }
            self.link = nil; self.deviceName = nil
            self.pairTimeout?.cancel()
            self.sample = nil; self.reference = nil; self.lastArrival = nil
            self.resetNeutralPosition()
            self.resetMovement()
            self.orientation = .identity; self.receivedFPS = 0; self.frameCount = 0
            self.isPaused = false; self.isStale = false
            self.pairingCode = Self.makeCode(excluding: self.pairingCode)
            self.status = "Ready to pair"
            if reason != "Disconnected" { self.errorMessage = reason }
        }
        channel.start()
    }

    func calibrate(confirmNeutral: Bool = false) {
        guard let sample else { return }
        reference = sample.attitude
        isNeutralConfirmed = confirmNeutral && neutralCheck.isReady
        poseRevision += 1
        orientation = .identity
        resetMovement()
        link?.send(LinkMessage(kind: .calibrate))
    }

    func confirmNeutralPosition() {
        guard neutralCheck.isReady, deviceName != nil, !isPaused, !isStale else { return }
        calibrate(confirmNeutral: true)
    }

    func resetNeutralPosition() {
        isNeutralConfirmed = false
        neutralCheck = .init()
        neutralMonitor.reset()
        resetSwordTranslation()
        poseRevision += 1
    }

    private func resetSwordTranslation() {
        swordTranslation.reset()
        swordDisplacement = .zero
        poseRevision += 1
    }

    func resetMovement(notifyPhone: Bool = false) {
        resetSwordTranslation()
        motionTracker.reset()
        movement = .unavailable
        if notifyPhone { link?.send(LinkMessage(kind: .resetMovement)) }
    }

    func restart() { stop(); start() }

    func disconnect() { link?.close(); errorMessage = nil }

    func stop() {
        disconnect()
        stopDemo()
        resetMovement()
        let oldListener = listener
        listener = nil
        oldListener?.stateUpdateHandler = nil
        oldListener?.newConnectionHandler = nil
        oldListener?.cancel()
        metricsTask?.cancel(); metricsTask = nil
        pairTimeout?.cancel()
        isListening = false
        status = "Receiver stopped"
    }

    func toggleDemo() {
        if isDemo { stopDemo(); return }
        guard deviceName == nil else { return }
        isDemo = true
        demoTask = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                guard let self else { break }
                let t = Float(Date().timeIntervalSince(start))
                let rotation = MotionQuaternion(
                    simd_quatf(angle: sin(t * 0.7) * 0.8, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: sin(t) * 0.35, axis: SIMD3(1, 0, 0)))
                // Known synthetic trajectory makes both vector arrows and braking visible.
                let velocity = SIMD3<Float>(0.55 * cos(t), 0.2 * cos(t * 0.6), 0.3 * sin(t * 0.8))
                let acceleration = SIMD3<Float>(-0.55 * sin(t), -0.12 * sin(t * 0.6), 0.24 * cos(t * 0.8))
                self.orientation = rotation
                self.movement = MotionEstimate(acceleration: MotionVector(acceleration), velocity: MotionVector(velocity),
                                               isAvailable: true, isRotating: true)
                self.sample = MotionSample(sequence: 0, timestamp: Double(t), attitude: rotation,
                                          rotationRate: MotionVector(x: 0.35 * cos(Double(t)), y: 0.56 * cos(Double(t) * 0.7), z: 0),
                                          acceleration: MotionVector(acceleration / LinearMotionTracker.standardGravity),
                                          gravity: MotionVector(x: 0, y: -1, z: 0))
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
    }

    private func stopDemo() {
        demoTask?.cancel(); demoTask = nil
        isDemo = false
        sample = nil
        orientation = .identity
        resetMovement()
    }
}
