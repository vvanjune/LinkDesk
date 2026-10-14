import Foundation
import AppKit
let recoveryDefaults = UserDefaults(suiteName: "local.linkdesk.tests.recovery")!
@main struct RecoveryModelTests {
 static func main() {
  recoveryDefaults.removePersistentDomain(forName: "local.linkdesk.tests.recovery")
  defer { recoveryDefaults.removePersistentDomain(forName: "local.linkdesk.tests.recovery") }
  let model = LinkModel()
  model.autoConnect = true; model.title = "manual-stop-sentinel"
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
  model.stop()
  RunLoop.main.run(until: Date().addingTimeInterval(3.7))
  precondition(!model.autoConnect && !model.running && model.title == "manual-stop-sentinel", "queued wake restarted manual stop")
  model.autoConnect = true
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
  model.autoConnect = false
  RunLoop.main.run(until: Date().addingTimeInterval(3.7))
  precondition(!model.running && model.title == "manual-stop-sentinel", "disabled auto connection still recovered")
  model.autoConnect = true
  NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
  RunLoop.main.run(until: Date().addingTimeInterval(3.7))
  precondition(model.title != "manual-stop-sentinel" || model.issue != nil, "wake observer did not attempt recovery")
  precondition(!model.running, "test unexpectedly started a core")
  model.autoConnect = false
  model.server = false
  model.manualName = "Selected-Peer"; model.manualAddress = "192.0.2.10"
  model.manualFingerprint = String(repeating: "a", count: 64)
  model.addManualDevice(); precondition(model.pairing != nil, "pairing did not open")
  model.trustPeer()
  model.running = true; model.connected = true; model.autoConnect = true
  model.observeDevice(PairedDevice(fingerprint: String(repeating: "a", count: 64), name: "Selected-Peer", address: "192.0.2.10", platform: "Windows", role: "client", lastSeen: Date().timeIntervalSince1970))
  precondition(model.running && model.connected && model.autoConnect, "cached role stopped a healthy pinned connection")
  model.observeDevice(PairedDevice(fingerprint: String(repeating: "b", count: 64), name: "Other-Peer", address: "192.0.2.11", platform: "Windows", role: "server", lastSeen: Date().timeIntervalSince1970))
  precondition(model.peerName == "Selected-Peer" && model.host == "192.0.2.10", "different fingerprint substituted for selection")
  model.running = false; model.connected = false
  model.shutdown()
  print("Mac recovery model checks passed: pending wake respects manual stop and disabled auto-connect; enabled wake reaches recovery; stale role cannot stop a healthy selected connection or substitute another identity.")
 }
}
