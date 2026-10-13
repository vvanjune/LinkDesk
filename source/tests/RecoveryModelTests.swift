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
  model.shutdown()
  print("Mac recovery model checks passed: pending wake respects manual stop and disabled auto-connect; enabled wake reaches recovery.")
 }
}
