import Foundation
import ObjectiveC
import WebRTC

/// RTCDataChannel drops messages that arrive while it has no delegate. This
/// relay is installed the moment a channel exists (on WebRTC's own thread)
/// and buffers messages until the real consumer attaches.
final class ChannelRelay: NSObject, RTCDataChannelDelegate {
    private static var key: UInt8 = 0
    private let lock = NSLock()
    private var pending: [RTCDataBuffer] = []
    private weak var target: RTCDataChannelDelegate?

    static func install(on channel: RTCDataChannel) {
        guard objc_getAssociatedObject(channel, &key) == nil else { return }
        let relay = ChannelRelay()
        objc_setAssociatedObject(channel, &key, relay, .OBJC_ASSOCIATION_RETAIN)
        channel.delegate = relay
    }

    /// Routes the channel's events to `target`, delivering anything buffered first.
    static func attach(_ channel: RTCDataChannel, to target: RTCDataChannelDelegate?) {
        install(on: channel)
        guard let relay = objc_getAssociatedObject(channel, &key) as? ChannelRelay else { return }
        relay.lock.lock()
        relay.target = target
        let buffered = relay.pending
        relay.pending.removeAll()
        if let target {
            for buffer in buffered { target.dataChannel(channel, didReceiveMessageWith: buffer) }
        }
        relay.lock.unlock()
        target?.dataChannelDidChangeState(channel)
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        lock.lock(); let target = self.target; lock.unlock()
        target?.dataChannelDidChangeState(dataChannel)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let target { target.dataChannel(dataChannel, didReceiveMessageWith: buffer) } else { pending.append(buffer) }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        lock.lock(); let target = self.target; lock.unlock()
        target?.dataChannel?(dataChannel, didChangeBufferedAmount: amount)
    }
}
