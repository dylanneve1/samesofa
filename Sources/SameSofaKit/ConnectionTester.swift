import Foundation
import WebRTC

/// Settings ▸ Connection ▸ "Test connection": is the room server there, and
/// (if a TURN relay is configured) does the relay hand out an allocation
/// with these credentials? One plain line each.
public final class ConnectionTester: NSObject {
    public struct Line: Equatable, Sendable {
        public var ok: Bool
        public var text: String
    }

    public struct Result: Equatable, Sendable {
        public var server: Line
        /// nil: no relay configured.
        public var relay: Line?
    }

    private var keepAlive: ConnectionTester?
    private var relayProbe: RelayProbe?
    private var serverProbe: ServerProbe?

    /// Runs both checks; `completion` is called once on the main queue.
    public static func run(serverURL: String, ice: IceSettings, timeout: TimeInterval = 10, completion: @escaping (Result) -> Void) {
        let tester = ConnectionTester()
        tester.keepAlive = tester
        var server: Line?, relay: Line?
        let turn = ice.turnURL.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var relayDone = turn.isEmpty
        func finish() {
            guard let server, relayDone, tester.keepAlive != nil else { return }
            tester.keepAlive = nil
            completion(Result(server: server, relay: relay))
        }
        tester.serverProbe = ServerProbe(address: serverURL, timeout: timeout) { line in
            server = line
            finish()
        }
        if !turn.isEmpty {
            tester.relayProbe = RelayProbe(urls: turn, username: ice.turnUsername, credential: ice.turnCredential, timeout: timeout) { line in
                relay = line
                relayDone = true
                finish()
            }
        }
    }
}

/// Opens the WebSocket and waits for the room server's answer to "ping".
private final class ServerProbe: NSObject, URLSessionWebSocketDelegate {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var completion: ((ConnectionTester.Line) -> Void)?
    private var opened = false

    init(address: String, timeout: TimeInterval, completion: @escaping (ConnectionTester.Line) -> Void) {
        self.completion = completion
        super.init()
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), let scheme = url.scheme, ["ws", "wss"].contains(scheme),
              url.host != nil, !address.contains("CHANGE-ME") else {
            DispatchQueue.main.async { self.finish(false, "Room server: no usable address. It looks like wss://sofa.example.org; enter the one you were given.") }
            return
        }
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(.string(let text)) = result, text.contains("\"pong\"") {
                    self.finish(true, "Room server: reachable.")
                } else if case .success = result {
                    self.finish(false, "Room server: something answered at that address, but not a SameSofa room server. Check the address.")
                } else if self.opened {
                    self.finish(false, "Room server: connected, then the connection was closed. Try again; if it stays like this, check the address.")
                }
                // A failure before the connection opened is reported by the delegate below.
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(false, "Room server: no answer within \(Int(timeout)) seconds. Check the address and this Mac's internet connection.")
        }
    }

    private func finish(_ ok: Bool, _ text: String) {
        guard let completion else { return }
        self.completion = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        completion(ConnectionTester.Line(ok: ok, text: text))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened = true
        webSocketTask.send(.string("{\"type\":\"ping\"}")) { _ in }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        switch error.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            finish(false, "Room server: that address doesn't exist. Check the spelling.")
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            finish(false, "Room server: this Mac has no internet connection right now.")
        case NSURLErrorCannotConnectToHost:
            finish(false, "Room server: nothing is answering at that address. Check the address, or ask whoever runs the server whether it is up.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            finish(false, "Room server: its security certificate was not accepted. Whoever runs the server needs to renew or fix it.")
        case NSURLErrorTimedOut:
            finish(false, "Room server: no answer. Check the address and this Mac's internet connection.")
        case NSURLErrorBadServerResponse:
            finish(false, "Room server: something answered at that address, but not a SameSofa room server. Check the address.")
        default:
            finish(false, "Room server: couldn't connect (\(error.localizedDescription))")
        }
    }
}

/// Asks WebRTC for relay candidates only: one arriving means the relay
/// accepted the credentials and made an allocation.
private final class RelayProbe: NSObject, RTCPeerConnectionDelegate {
    private let factory: RTCPeerConnectionFactory
    private let audio = AudioHub(mode: .synthetic)
    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var completion: ((ConnectionTester.Line) -> Void)?
    private var refusal: Int?

    init(urls: [String], username: String, credential: String, timeout: TimeInterval, completion: @escaping (ConnectionTester.Line) -> Void) {
        self.completion = completion
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audio)
        super.init()
        guard urls.allSatisfy({ $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }) else {
            DispatchQueue.main.async { self.finish(false, "Relay (TURN): the address has to start with turn: or turns:, for example turn:turn.example.org:3478.") }
            return
        }
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: urls, username: username, credential: credential)]
        config.iceTransportPolicy = .relay
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            DispatchQueue.main.async { self.finish(false, "Relay (TURN): the address could not be used. It looks like turn:turn.example.org:3478.") }
            return
        }
        self.pc = pc
        channel = pc.dataChannel(forLabel: "probe", configuration: RTCDataChannelConfiguration())
        pc.offer(for: constraints) { [weak self] description, _ in
            guard let description else {
                DispatchQueue.main.async { self?.finish(false, "Relay (TURN): the test could not be started.") }
                return
            }
            pc.setLocalDescription(description) { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.failed() }
    }

    private func failed() {
        switch refusal {
        case 401, 431, 438, 441:
            finish(false, "Relay (TURN): it refused the username or password. Check both.")
        case 403, 437, 486, 508:
            finish(false, "Relay (TURN): it answered but would not relay (quota or policy on the relay). Ask whoever runs it.")
        default:
            finish(false, "Relay (TURN): no answer. Check the address and port; some networks also block relays.")
        }
    }

    private func finish(_ ok: Bool, _ text: String) {
        guard let completion else { return }
        self.completion = nil
        channel?.close()
        pc?.close()
        pc = nil
        completion(ConnectionTester.Line(ok: ok, text: text))
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // Only relay candidates are gathered at all; be strict anyway.
        guard candidate.sdp.contains(" typ relay") else { return }
        DispatchQueue.main.async { self.finish(true, "Relay (TURN): working.") }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGatherIceCandidate event: RTCIceCandidateErrorEvent) {
        let code = Int(event.errorCode)
        DispatchQueue.main.async { if self.refusal == nil || (400..<600).contains(code) { self.refusal = code } }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        // Everything was tried and no relay candidate came.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.failed() }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
