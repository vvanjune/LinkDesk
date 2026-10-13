import Foundation
import AppKit
@main struct DiscoveryResponderTests {
    static func main() throws {
        precondition(DiscoveryQuery(magic: "linkdesk-discover", version: 1, nonce: String(repeating: "a", count: 64), name: "Mac-One").valid)
        precondition(!DiscoveryQuery(magic: "linkdesk-discover", version: 1, nonce: "replay", name: "Mac-One").valid)
        precondition(!DiscoveryQuery(magic: "linkdesk-discover", version: 1, nonce: String(repeating: "a", count: 64), name: "Mac\n[security]").valid)
        let service = DiscoveryResponder(trace: { print($0); fflush(stdout) })
        precondition(service.start(name: "Mac-One", identity: URL(fileURLWithPath: CommandLine.arguments[1])))
        print("Discovery test responder ready"); fflush(stdout)
        Thread.sleep(forTimeInterval: 20); service.stop()
        if let icon = NSImage(contentsOfFile: CommandLine.arguments[2]) { precondition(!icon.representations.isEmpty); print("Native ICNS loaded successfully") }
        else { fatalError("ICNS rejected") }
    }
}
