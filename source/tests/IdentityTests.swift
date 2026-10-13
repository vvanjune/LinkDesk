import Foundation
@main struct IdentityTests {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("linkdesk-identity-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let pin = try LinkIdentity.prepare(at: original)
        check(pin.count == 95)
        let identity = original.appendingPathComponent("tls/deskflow.pem")
        let before = try Data(contentsOf: identity)
        check(try LinkIdentity.prepare(at: original) == pin)
        check(try Data(contentsOf: identity) == before)
        let permissions = try fm.attributesOfItem(atPath: identity.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600)
        let db = original.appendingPathComponent("tls/trusted-servers")
        try "v2:sha256:test-only\n".write(to: db, atomically: true, encoding: .utf8)
        let migrated = root.appendingPathComponent("migrated")
        check(try LinkIdentity.prepare(at: migrated, legacy: original.appendingPathComponent("tls")) == pin)
        check(try Data(contentsOf: migrated.appendingPathComponent("tls/deskflow.pem")) == before)
        check(try Data(contentsOf: migrated.appendingPathComponent("tls/trusted-servers")) == Data(contentsOf: db))
        let broken = root.appendingPathComponent("broken")
        try fm.createDirectory(at: broken.appendingPathComponent("tls"), withIntermediateDirectories: true)
        let brokenFile = broken.appendingPathComponent("tls/deskflow.pem")
        try Data("invalid identity".utf8).write(to: brokenFile)
        do { _ = try LinkIdentity.prepare(at: broken); fatalError("corrupt identity silently replaced") } catch {}
        check(try String(contentsOf: brokenFile, encoding: .utf8) == "invalid identity")
        if CommandLine.arguments.count == 3 {
            check(try LinkIdentity.fingerprint(URL(fileURLWithPath: CommandLine.arguments[1])) == CommandLine.arguments[2])
        }
        print("Mac identity checks passed: fresh generation, stable reuse, migration, private permissions, corruption preservation and cross-platform fingerprint.")
    }
}
