import CryptoKit
import Foundation
import SameSofaKit

// Settings ▸ Connection ▸ Test connection, against a room server on this Mac
// and a stand-in TURN relay in this process (no real relay is contacted):
//
//   samesofa-itest --connection-test ws://127.0.0.1:8787
//
// The stand-in speaks just enough TURN (RFC 5766 Allocate and Refresh with
// long-term credentials over UDP) for WebRTC to obtain a relay candidate.

enum ConnectionTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !ok { failures += 1 }
    }

    static func test(server: String, ice: IceSettings, timeout: TimeInterval = 6) -> ConnectionTester.Result {
        var result: ConnectionTester.Result?
        ConnectionTester.run(serverURL: server, ice: ice, timeout: timeout) { result = $0 }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return result!
    }

    static func run(server: String) -> Never {
        let noRelay = IceSettings(turnURL: "")
        var r = test(server: server, ice: noRelay)
        check("room server reachable, no relay configured", r.server.ok && r.relay == nil, r.server.text)
        r = test(server: "ws://127.0.0.1:9", ice: noRelay)
        check("nothing listening: plain failure line", !r.server.ok && r.server.text.hasPrefix("Room server:"), r.server.text)
        r = test(server: "wss://CHANGE-ME.example", ice: noRelay)
        check("placeholder address: says what an address looks like", !r.server.ok, r.server.text)
        r = test(server: "wss://no-such-host.invalid", ice: noRelay)
        check("unknown host: plain failure line", !r.server.ok, r.server.text)
        r = test(server: "http://example.org", ice: noRelay)
        check("not a WebSocket address", !r.server.ok, r.server.text)

        guard let address = FakeRelay.localAddress(), let relay = FakeRelay(address: address, username: "sofa", password: "correct horse", realm: "test") else {
            check("stand-in relay started", false, "no network interface with an IPv4 address")
            finish()
        }
        let url = "turn:\(address):\(relay.port)?transport=udp"
        r = test(server: server, ice: IceSettings(turnURL: url, turnUsername: "sofa", turnCredential: "correct horse"))
        check("relay with the right credentials: allocation succeeds", r.server.ok && r.relay?.ok == true, r.relay?.text ?? "no relay line")
        check("the stand-in relay really made an allocation", relay.allocations >= 1, "\(relay.allocations) allocation(s), \(relay.refused) refused")
        let refusedBefore = relay.refused, allocationsBefore = relay.allocations
        r = test(server: server, ice: IceSettings(turnURL: url, turnUsername: "sofa", turnCredential: "wrong"))
        check("relay with a wrong password: plain failure line", r.relay?.ok == false && relay.refused > refusedBefore && relay.allocations == allocationsBefore,
              r.relay?.text ?? "no relay line")
        r = test(server: server, ice: IceSettings(turnURL: "turn:\(address):9", turnUsername: "sofa", turnCredential: "x"))
        check("no relay at that address: plain failure line", r.relay?.ok == false, r.relay?.text ?? "no relay line")
        r = test(server: server, ice: IceSettings(turnURL: "turn.example.org:3478", turnUsername: "sofa", turnCredential: "x"))
        check("relay address without turn: is explained", r.relay?.ok == false && r.relay!.text.contains("turn:"), r.relay?.text ?? "")
        relay.stop()
        finish()
    }

    static func finish() -> Never {
        print("SUMMARY \(failures == 0 ? "all connection test checks passed" : "\(failures) connection test checks FAILED")")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Just enough of a TURN server for one client to obtain an allocation.
final class FakeRelay {
    let port: UInt16
    private let socketDescriptor: Int32
    private let key: SymmetricKey
    private let username: String, realm: String
    private let nonce = "f00dfeedf00dfeed"
    private let lock = NSLock()
    private var allocationCount = 0, refusedCount = 0
    private var running = true

    var allocations: Int { lock.lock(); defer { lock.unlock() }; return allocationCount }
    var refused: Int { lock.lock(); defer { lock.unlock() }; return refusedCount }

    /// An IPv4 address of this Mac that is not the loopback one.
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }

    init?(address: String, username: String, password: String, realm: String) {
        self.username = username
        self.realm = realm
        key = SymmetricKey(data: Data(Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8))))
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        socketDescriptor = descriptor
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_pton(AF_INET, address, &local.sin_addr)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        port = UInt16(bigEndian: local.sin_port)
        guard descriptor >= 0, bound == 0, named == 0 else { close(descriptor); return nil }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Thread { [self] in serve() }.start()
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    private func serve() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            lock.lock(); let go = running; lock.unlock()
            guard go else { break }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketDescriptor, &buffer, buffer.count, 0, $0, &length) } }
            guard count >= 20 else { continue }
            guard let reply = answer(Array(buffer[0..<count]), from: from) else { continue }
            _ = reply.withUnsafeBytes { bytes in
                withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socketDescriptor, bytes.baseAddress, reply.count, 0, $0, length) } }
            }
        }
        close(socketDescriptor)
    }

    private func attribute(_ type: UInt16, _ value: [UInt8]) -> [UInt8] {
        var out = [UInt8(type >> 8), UInt8(type & 0xff), UInt8(value.count >> 8), UInt8(value.count & 0xff)] + value
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    private func xorAddress(_ type: UInt16, port: UInt16, address: UInt32) -> [UInt8] {
        let p = port ^ 0x2112, a = address ^ 0x2112_A442
        return attribute(type, [0, 1, UInt8(p >> 8), UInt8(p & 0xff), UInt8(a >> 24), UInt8(a >> 16 & 0xff), UInt8(a >> 8 & 0xff), UInt8(a & 0xff)])
    }

    /// A message of `type` answering `request`, with MESSAGE-INTEGRITY when `signed`.
    private func message(_ type: UInt16, request: [UInt8], attributes: [UInt8], signed: Bool) -> [UInt8] {
        func header(_ length: Int) -> [UInt8] { [UInt8(type >> 8), UInt8(type & 0xff), UInt8(length >> 8), UInt8(length & 0xff)] + request[4..<20] }
        guard signed else { return header(attributes.count) + attributes }
        let covered = header(attributes.count + 24) + attributes
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(covered), using: key))
        return covered + attribute(0x0008, mac)
    }

    private func answer(_ request: [UInt8], from: sockaddr_in) -> [UInt8]? {
        let type = UInt16(request[0]) << 8 | UInt16(request[1])
        guard request[4...7].elementsEqual([0x21, 0x12, 0xA4, 0x42]) else { return nil }
        let clientPort = UInt16(bigEndian: from.sin_port), clientAddress = UInt32(bigEndian: from.sin_addr.s_addr)
        if type == 0x0001 { // Binding
            return message(0x0101, request: request, attributes: xorAddress(0x0020, port: clientPort, address: clientAddress), signed: false)
        }
        guard type == 0x0003 || type == 0x0004 else { return nil } // Allocate, Refresh
        // Find MESSAGE-INTEGRITY and check it.
        var offset = 20, integrityOffset: Int?, mac: [UInt8] = []
        while offset + 4 <= request.count {
            let attributeType = UInt16(request[offset]) << 8 | UInt16(request[offset + 1])
            let length = Int(request[offset + 2]) << 8 | Int(request[offset + 3])
            guard offset + 4 + length <= request.count else { break }
            if attributeType == 0x0008 { integrityOffset = offset; mac = Array(request[(offset + 4)..<(offset + 4 + length)]) }
            offset += 4 + (length + 3) / 4 * 4
        }
        var authorised = false
        if let integrityOffset {
            var covered = Array(request[0..<integrityOffset])
            let length = integrityOffset - 20 + 24
            covered[2] = UInt8(length >> 8)
            covered[3] = UInt8(length & 0xff)
            authorised = Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(covered), using: key)) == mac
        }
        guard authorised else {
            if integrityOffset != nil { lock.lock(); refusedCount += 1; lock.unlock() }
            let error = attribute(0x0009, [0, 0, 4, 1] + Array("Unauthorized".utf8)) + attribute(0x0014, Array(realm.utf8)) + attribute(0x0015, Array(nonce.utf8))
            return message(type | 0x0110, request: request, attributes: error, signed: false)
        }
        let lifetime = attribute(0x000D, [0, 0, 2, 0x58])
        if type == 0x0004 { return message(0x0104, request: request, attributes: lifetime, signed: true) }
        lock.lock(); allocationCount += 1; lock.unlock()
        let relayed = xorAddress(0x0016, port: 50_000, address: clientAddress)
        return message(0x0103, request: request, attributes: relayed + xorAddress(0x0020, port: clientPort, address: clientAddress) + lifetime, signed: true)
    }
}
