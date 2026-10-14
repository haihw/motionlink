import Foundation
import Network

@MainActor
final class LinkConnection {
    let id = UUID()
    private let connection: NWConnection
    private var decoder = FrameDecoder()
    private var closed = false
    private var sendingMotion = false
    var onReady: (() -> Void)?
    var onMessage: ((LinkMessage) -> Void)?
    var onClose: ((String) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch state {
                case .ready: self.onReady?(); self.receive()
                case .failed(let error): self.close(reason: error.localizedDescription)
                case .waiting(let error): self.close(reason: error.localizedDescription)
                case .cancelled: self.close(reason: "Disconnected")
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    @discardableResult
    func send(_ message: LinkMessage, completion: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        guard !closed else { return false }
        let isMotion = message.kind == .motion
        // At most one motion frame in flight. Drop old samples instead of building latency.
        guard !isMotion || !sendingMotion else { return false }
        do {
            let data = try FrameDecoder.encode(message)
            if isMotion { sendingMotion = true }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    if isMotion { self.sendingMotion = false }
                    if let error { self.close(reason: error.localizedDescription) }
                    else { completion?() }
                }
            })
            return true
        } catch { close(reason: "Could not encode motion data"); return false }
    }

    func close(reason: String = "Disconnected") {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onReady = nil; onMessage = nil; onClose = nil
        callback?(reason)
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                do {
                    if let data {
                        for message in try self.decoder.append(data) {
                            guard !self.closed else { break }
                            self.onMessage?(message)
                        }
                    }
                    if let error { self.close(reason: error.localizedDescription) }
                    else if complete { self.close(reason: "The other app disconnected") }
                    else { self.receive() }
                } catch { self.close(reason: "Invalid or incompatible data received") }
            }
        }
    }
}

enum LinkSettings {
    static let serviceType = "_motionlink._tcp"
    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
        }
        return parameters
    }
}
