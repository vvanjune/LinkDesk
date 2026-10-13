import Foundation
import CryptoKit

enum LinkIdentity {
    static func openssl(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LinkDesk.Identity", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取或生成本机加密身份。请保留数据目录并查看权限，不要删除已配对的证书。"])
        }
        return data
    }
    static func fingerprint(_ pem: URL) throws -> String {
        let certificate = try openssl(["x509", "-in", pem.path, "-outform", "DER"])
        let publicKey = try openssl(["x509", "-in", pem.path, "-pubkey", "-noout"])
        let privatePublicKey = try openssl(["pkey", "-in", pem.path, "-pubout"])
        guard publicKey == privatePublicKey else {
            throw NSError(domain: "LinkDesk.Identity", code: 2, userInfo: [NSLocalizedDescriptionKey: "本机证书与私钥不匹配。已保留原文件，请恢复正确的证书备份。"])
        }
        return SHA256.hash(data: certificate).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    @discardableResult static func prepare(at profile: URL, legacy: URL? = nil) throws -> String {
        let fm = FileManager.default
        let tls = profile.appendingPathComponent("tls")
        try fm.createDirectory(at: tls, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tls.path)
        let identity = tls.appendingPathComponent("deskflow.pem")
        if !fm.fileExists(atPath: identity.path) {
            let staging = tls.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let candidate = staging.appendingPathComponent("identity.pem")
            if let old = legacy, fm.fileExists(atPath: old.appendingPathComponent("deskflow.pem").path) {
                try fm.copyItem(at: old.appendingPathComponent("deskflow.pem"), to: candidate)
                _ = try fingerprint(candidate)
                for name in ["trusted-clients", "trusted-servers"] {
                    let destination = tls.appendingPathComponent(name)
                    let original = old.appendingPathComponent(name)
                    if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: original.path) {
                        try fm.copyItem(at: original, to: destination)
                        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    }
                }
            } else {
                let key = staging.appendingPathComponent("key.pem")
                let cert = staging.appendingPathComponent("cert.pem")
                _ = try openssl(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "3650", "-subj", "/CN=LinkDesk", "-keyout", key.path, "-out", cert.path])
                try (Data(contentsOf: key) + Data(contentsOf: cert)).write(to: candidate)
                _ = try fingerprint(candidate)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
            try fm.moveItem(at: candidate, to: identity)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identity.path)
        return try fingerprint(identity)
    }
}
