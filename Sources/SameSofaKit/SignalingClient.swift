import Foundation

/// Talks to the room server (server/server.js) over a WebSocket.
/// All callbacks arrive on the main queue.
public final class SignalingClient: NSObject, URLSessionWebSocketDelegate {
    public enum Event {
        case connected
        case created(code: String)
        case joined(code: String)
        case peerJoined
        case peerLeft
        case roomClosed
        case signal([String: Any])
        case error(String)
        case disconnected
    }

    public var onEvent: ((Event) -> Void)?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var openContinuation: ((Bool) -> Void)?

    public override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    public func connect(to url: URL) {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        self.task = task
        task.resume()
        receive()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.send(["type": "ping"])
        }
    }

    public func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    public func createRoom() { send(["type": "create"]) }
    public func joinRoom(code: String) { send(["type": "join", "code": code]) }
    public func leaveRoom() { send(["type": "leave"]) }
    public func signal(_ data: [String: Any]) { send(["type": "signal", "data": data]) }

    private func send(_ object: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure:
                    self.closed()
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "created": onEvent?(.created(code: object["code"] as? String ?? ""))
        case "joined": onEvent?(.joined(code: object["code"] as? String ?? ""))
        case "peer-joined": onEvent?(.peerJoined)
        case "peer-left": onEvent?(.peerLeft)
        case "room-closed": onEvent?(.roomClosed)
        case "signal": if let payload = object["data"] as? [String: Any] { onEvent?(.signal(payload)) }
        case "error": onEvent?(.error(object["error"] as? String ?? "unknown"))
        default: break
        }
    }

    private func closed() {
        guard task != nil else { return }
        task = nil
        pingTimer?.invalidate()
        onEvent?(.disconnected)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onEvent?(.connected)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closed()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { closed() }
    }
}
