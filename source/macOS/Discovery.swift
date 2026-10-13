import Foundation
import Darwin

struct DiscoveryQuery: Codable {
    let magic: String
    let version: Int
    let nonce: String
    let name: String
    var valid: Bool {
        magic == "linkdesk-discover" && version == 1 && LinkConfiguration.validName(name) &&
        nonce.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}
struct DiscoveryOffer: Encodable {
    let magic = "linkdesk-offer"
    let version = 1
    let nonce: String
    let name: String
    let address: String
    let port = 24800
    let certificate: String
    let signature: String
    static func signedMessage(nonce: String, name: String, address: String) -> Data {
        Data("LinkDesk/1\n\(nonce)\n\(name)\n\(address)\n24800\n".utf8)
    }
}

// Discovery announces the public certificate only. A fresh challenge is signed
// with the existing Deskflow identity; the receiver verifies its stored pin.
final class DiscoveryResponder {
    private let lock = NSLock()
    private var stopped = false
    private var descriptor: Int32 = -1
    private let trace: (String) -> Void
    init(trace: @escaping (String) -> Void = { _ in }) { self.trace = trace }
    private static func openssl(_ arguments: [String], input: Data? = nil) -> Data? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); p.arguments = arguments
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let incoming = Pipe(); p.standardInput = incoming
        do {
            try p.run()
            if let input = input { incoming.fileHandleForWriting.write(input) }
            try? incoming.fileHandleForWriting.close()
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
    func start(name: String, identity: URL) -> Bool {
        guard LinkConfiguration.validName(name),
              let cert = Self.openssl(["x509", "-in", identity.path, "-outform", "DER"]), cert.count <= 4096 else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return false }
        var endpoint = sockaddr_in(); endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET); endpoint.sin_port = UInt16(24801).bigEndian
        let bound = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { Darwin.close(fd); return false }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        lock.lock(); descriptor = fd; stopped = false; lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { Darwin.close(fd) }
            var lastReply = Date.distantPast
            while true {
                lock.lock(); let done = stopped; lock.unlock(); if done { break }
                var sender = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = withUnsafeMutablePointer(to: &sender) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.recvfrom(fd, &bytes, bytes.count, 0, $0, &length) }
                }
                if count > 0 { trace("Received discovery query: \(count) bytes") }
                guard count > 0, count < bytes.count, Date().timeIntervalSince(lastReply) >= 1,
                      let query = try? JSONDecoder().decode(DiscoveryQuery.self, from: Data(bytes.prefix(count))),
                      query.valid, query.name == name, let address = Self.localAddress(for: sender) else { continue }
                lastReply = Date()
                let message = DiscoveryOffer.signedMessage(nonce: query.nonce, name: name, address: address)
                trace("Validated query, replying from \(address)")
                guard let signature = Self.openssl(["dgst", "-sha256", "-sign", identity.path], input: message), signature.count <= 1024 else { trace("Signing failed"); continue }
                let offer = DiscoveryOffer(nonce: query.nonce, name: name, address: address, certificate: cert.base64EncodedString(), signature: signature.base64EncodedString())
                guard let response = try? JSONEncoder().encode(offer), response.count <= 8192 else { continue }
                let sent = response.withUnsafeBytes { buffer in
                    withUnsafePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(fd, buffer.baseAddress, buffer.count, 0, $0, length) } }
                }
                trace("Sent discovery response: \(sent) bytes")
            }
        }
        return true
    }
    private static func localAddress(for peer: sockaddr_in) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return nil }; defer { Darwin.close(fd) }
        var peer = peer
        let result = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { return nil }
        var own = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &own, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }) == 0 else { return nil }
        var address = own.sin_addr; var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { return nil }
        return String(cString: text)
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    deinit { stop() }
}
