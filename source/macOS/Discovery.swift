import Foundation
import Darwin
import CryptoKit
import Security

struct DiscoveryQuery: Codable {
    let magic: String
    let version: Int
    let nonce: String
    let name: String
    var valid: Bool {
        magic == "linkdesk-discover" && [1, 2].contains(version) &&
        (version == 2 ? (name.isEmpty || LinkConfiguration.validName(name)) : LinkConfiguration.validName(name)) &&
        nonce.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
struct DiscoveryOffer: Codable {
    var magic = "linkdesk-offer"
    var version = 2
    let nonce: String
    let name: String
    let address: String
    var port = 24800
    var platform = "macOS"
    var role = "server"
    let certificate: String
    let signature: String
    static func signedMessage(nonce: String, name: String, address: String, platform: String = "macOS", role: String = "server", version: Int = 1) -> Data {
        let base = "LinkDesk/\(version)\n\(nonce)\n\(name)\n\(address)\n24800\n"
        return Data((base + (version == 2 ? "\(platform)\n\(role)\n" : "")).utf8)
    }
}
enum DiscoveryVerifier {
    static func authenticate(_ offer: DiscoveryOffer, nonce: String, source: String) -> PairedDevice? {
        guard offer.magic == "linkdesk-offer", offer.version == 2, offer.nonce == nonce,
              nonce.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              LinkConfiguration.validName(offer.name), offer.address == source, offer.port == 24800,
              ["macOS", "Windows"].contains(offer.platform), ["server", "client"].contains(offer.role),
              offer.certificate.count <= 6000, offer.signature.count <= 1500,
              let raw = Data(base64Encoded: offer.certificate), raw.count <= 4096,
              let signature = Data(base64Encoded: offer.signature),
              let cert = SecCertificateCreateWithData(nil, raw as CFData), let key = SecCertificateCopyKey(cert) else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, source, &address) == 1 else { return nil }
        let message = DiscoveryOffer.signedMessage(nonce: nonce, name: offer.name, address: offer.address, platform: offer.platform, role: offer.role, version: 2)
        let algorithm: SecKeyAlgorithm = SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256) ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
        guard SecKeyVerifySignature(key, algorithm, message as CFData, signature as CFData, nil) else { return nil }
        let pin = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        return PairedDevice(fingerprint: pin, name: offer.name, address: offer.address, platform: offer.platform, role: offer.role, lastSeen: Date().timeIntervalSince1970)
    }
}
enum DiscoveryNetwork {
    static func endpoint(_ address: String, port: UInt16) -> sockaddr_in? {
        var value = sockaddr_in(); value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        value.sin_family = sa_family_t(AF_INET); value.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &value.sin_addr) == 1 else { return nil }
        return value
    }
    static func text(_ value: sockaddr_in) -> String? {
        var address = value.sin_addr; var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
        return String(cString: text)
    }
    static func route(to peer: sockaddr_in) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return nil }; defer { Darwin.close(fd) }
        var peer = peer
        guard withUnsafePointer(to: &peer, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return nil }
        var own = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &own, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }) == 0 else { return nil }
        return text(own)
    }
    static func broadcasts() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return ["255.255.255.255"] }; defer { freeifaddrs(head) }
        var addresses = Set(["255.255.255.255"]); var current = head
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0, item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = item.pointee.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            guard netmask != 0 else { continue }
            var endpoint = sockaddr_in(); endpoint.sin_addr.s_addr = ip | ~netmask
            if let text = Self.text(endpoint) { addresses.insert(text) }
        }
        return Array(addresses)
    }
}
final class DiscoveryResponder {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var stopped = true
    private var descriptor: Int32 = -1
    private let trace: (String) -> Void
    init(trace: @escaping (String) -> Void = { _ in }) { self.trace = trace }
    private static func openssl(_ arguments: [String], input: Data? = nil) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = arguments
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let incoming = Pipe(); p.standardInput = incoming
        do {
            try p.run(); if let input = input { incoming.fileHandleForWriting.write(input) }
            try? incoming.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
    func start(name: String, identity: URL, role: String = "server", port: UInt16 = 24801) -> Bool {
        guard LinkConfiguration.validName(name), ["server", "client"].contains(role),
              let cert = Self.openssl(["x509", "-in", identity.path, "-outform", "DER"]), cert.count <= 4096 else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return false }
        var endpoint = DiscoveryNetwork.endpoint("0.0.0.0", port: port)!
        guard withUnsafePointer(to: &endpoint, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { Darwin.close(fd); return false }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        lock.lock(); descriptor = fd; stopped = false; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { Darwin.close(fd); lock.lock(); descriptor = -1; lock.unlock(); finished.signal() }
            var lastReply = Date.distantPast; var recent: [String: Date] = [:]
            while true {
                lock.lock(); let done = stopped; lock.unlock(); if done { break }
                var sender = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = withUnsafeMutablePointer(to: &sender) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(fd, &bytes, bytes.count, 0, $0, &length) } }
                guard count > 0, count < bytes.count, let source = DiscoveryNetwork.text(sender),
                      let query = try? JSONDecoder().decode(DiscoveryQuery.self, from: Data(bytes.prefix(count))), query.valid,
                      query.version == 2 || (query.name == name && role == "server"),
                      let address = DiscoveryNetwork.route(to: sender) else { continue }
                let now = Date()
                guard now.timeIntervalSince(lastReply) >= 0.125, now.timeIntervalSince(recent[source] ?? .distantPast) >= 1 else { continue }
                if recent.count > 256 { recent.removeAll() }; recent[source] = now; lastReply = now
                let message = DiscoveryOffer.signedMessage(nonce: query.nonce, name: name, address: address, role: role, version: query.version)
                guard let signature = Self.openssl(["dgst", "-sha256", "-sign", identity.path], input: message), signature.count <= 1024 else { continue }
                let offer = DiscoveryOffer(version: query.version, nonce: query.nonce, name: name, address: address, role: role, certificate: cert.base64EncodedString(), signature: signature.base64EncodedString())
                guard let response = try? JSONEncoder().encode(offer), response.count <= 8192 else { continue }
                _ = response.withUnsafeBytes { buffer in withUnsafePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(fd, buffer.baseAddress, buffer.count, 0, $0, length) } } }
                trace("Responded to discovery query")
            }
        }
        return true
    }
    func stop() {
        lock.lock(); stopped = true; let running = descriptor >= 0; lock.unlock()
        if running { _ = finished.wait(timeout: .now() + 2) }
    }
    deinit { stop() }
}
final class DiscoveryClient {
    private let lock = NSLock()
    private var cancelled = false
    private var requested = true
    private func done() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func refresh() { lock.lock(); requested = true; lock.unlock() }
    func stop() { lock.lock(); cancelled = true; lock.unlock() }
    init(ownPin: String, lastAddress: @escaping () -> String, found: @escaping (PairedDevice) -> Void, status: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while !done() {
                lock.lock(); requested = false; lock.unlock()
                let devices = Self.probe(addresses: DiscoveryNetwork.broadcasts() + [lastAddress()], ownPin: ownPin, cancelled: { self.done() })
                for device in devices { found(device) }
                status("局域网发现已开启 · 本轮发现 \(devices.count) 台电脑")
                let deadline = Date().addingTimeInterval(5 + Double.random(in: 0...1.5))
                while Date() < deadline && !done() {
                    lock.lock(); let refresh = requested; lock.unlock(); if refresh { break }; usleep(150_000)
                }
            }
        }
    }
    static func probe(addresses: [String], ownPin: String, port: UInt16 = 24801, cancelled: () -> Bool = { false }) -> [PairedDevice] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return [] }; defer { Darwin.close(fd) }
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var local = DiscoveryNetwork.endpoint("0.0.0.0", port: 0)!
        guard withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return [] }
        let nonce = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        guard let data = try? JSONEncoder().encode(DiscoveryQuery(magic: "linkdesk-discover", version: 2, nonce: nonce, name: "")) else { return [] }
        for address in Set(addresses) {
            guard var destination = DiscoveryNetwork.endpoint(address, port: port) else { continue }
            _ = data.withUnsafeBytes { bytes in withUnsafePointer(to: &destination) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        }
        let deadline = Date().addingTimeInterval(2.2); var devices: [String: PairedDevice] = [:]
        while Date() < deadline && !cancelled() {
            var sender = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size); var bytes = [UInt8](repeating: 0, count: 8192)
            let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(fd, &bytes, bytes.count, 0, $0, &length) } }
            guard count > 0, count < bytes.count, let source = DiscoveryNetwork.text(sender),
                  let offer = try? JSONDecoder().decode(DiscoveryOffer.self, from: Data(bytes.prefix(count))),
                  let device = DiscoveryVerifier.authenticate(offer, nonce: nonce, source: source), device.id != ownPin, devices.count < 128 else { continue }
            devices[device.id] = device
        }
        return Array(devices.values)
    }
    deinit { stop() }
}
