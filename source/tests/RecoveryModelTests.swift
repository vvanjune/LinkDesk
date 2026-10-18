import Foundation
import AppKit
import CryptoKit
@main struct RecoveryModelTests {
 static func runLoop(_ time: Double) { RunLoop.main.run(until: Date().addingTimeInterval(time)) }
 static func until(_ check: () -> Bool, seconds: Double = 8, line: UInt = #line) { let end = Date().addingTimeInterval(seconds); while !check() { precondition(Date() < end, "model wait timed out at line \(line)"); runLoop(0.05) } }
 static func main() throws {
  // Keep the private fixture socket below sockaddr_un's macOS path limit.
  let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("LinkDeskMacModel-"+UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let defaults = UserDefaults(suiteName: "local.linkdesk.tests."+UUID().uuidString)!
  defaults.set("FixtureMac", forKey: "localName"); defaults.set(true, forKey: "autoConnect"); defaults.set(false, forKey: "allowDiscovery")
  defaults.set(false, forKey: "server")
  let fixture = URL(fileURLWithPath: CommandLine.arguments[1]); let core = root.appendingPathComponent("fixture-core")
  try FileManager.default.copyItem(at: fixture, to: core); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: core.path)
  let hash = SHA256.hash(data: try Data(contentsOf: core)).map { String(format: "%02x", $0) }.joined()
  try JSONSerialization.data(withJSONObject: ["displaySafetyVersion": 1,"sha256":hash]).write(to: root.appendingPathComponent("linkdesk-core.json"))
  let store = try PeerStore(profile: root)
  let pin = String(repeating: "a", count: 64)
  _ = try store.observe(PairedDevice(fingerprint: pin, name: "FixturePeer", address: "127.0.0.1", platform: "Windows", role: "client", lastSeen: 0))
  try store.pair(pin)
  func launches() -> [String] { ((try? String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
  let model = LinkModel(defaults: defaults, profile: root, engine: core, observeSystemEvents: false, hasDeviceControl: {true}, desktopState: {MacDesktopSnapshot(ready: true, signature: "fixture-display")}, foreignCore: {false}, recoveryDelay: 0.03, ipcPath: root.appendingPathComponent("socket").path)
  defer { model.shutdown() }
  model.beginAutomaticStart(); for _ in 0..<100 { model.networkSignal() }; model.resumeSignal(); runLoop(0.2)
  precondition(launches().isEmpty && !model.running, "legacy auto-connect resurrected a session")
  precondition(!model.autoStartOnLaunch && !model.wakeDisplayOnRemoteInput, "upgrade defaults were unsafe")
  model.start(); until({model.connected}); precondition(launches().count == 1)
  for _ in 0..<100 { model.networkSignal() }; model.resumeSignal(); runLoop(0.4)
  precondition(launches().count == 1 && model.running, "healthy wake/network restarted core")
  precondition(model.logs.contains(where: {$0.contains("核心正常，保留进程")}), "native-style IPC probe did not preserve core")
  model.observeDevice(PairedDevice(fingerprint: pin, name: "FixturePeer", address: "127.0.0.2", platform: "Windows", role: "server", lastSeen: Date().timeIntervalSince1970))
  until({launches().count == 2 && model.connected})
  model.stop(); until({!model.running}); for _ in 0..<100 {model.networkSignal()}; model.resumeSignal(); runLoop(0.3)
  precondition(launches().count == 2 && model.autoConnect, "manual stop was undone or changed recovery preference")
  model.start(); until({model.connected}); try Data().write(to: root.appendingPathComponent("launches.hold")); model.resumeSignal()
  until({model.title == "共享核心暂未响应"}, seconds: 5); precondition(model.running && launches().count == 3, "unresponsive core killed/restarted")
  try FileManager.default.removeItem(at: root.appendingPathComponent("launches.hold")); model.stop(); until({!model.running})
  model.start(); until({model.connected}); try Data().write(to: root.appendingPathComponent("launches.crash")); model.networkSignal(); until({!model.running}); model.resumeSignal(); runLoop(0.3)
  precondition(launches().count == 4, "crash relaunched core automatically")
  model.shutdown()
  try FileManager.default.removeItem(at: root.appendingPathComponent("launches.crash"))
  let editing = LinkModel(defaults: defaults, profile: root, engine: core, observeSystemEvents: false, hasDeviceControl: {true}, desktopState: {MacDesktopSnapshot(ready: true, signature: "fixture-display")}, foreignCore: {false}, recoveryDelay: 0.03, ipcPath: root.appendingPathComponent("socket").path)
  editing.start(); until({editing.connected})
  let beforeEdit = launches().count
  editing.invertVertical.toggle(); editing.saveAndApply()
  until({launches().count == beforeEdit + 1 && editing.connected})
  editing.saveAndApply(); runLoop(0.2)
  precondition(launches().count == beforeEdit + 1, "unchanged settings reloaded core")
  editing.invertVertical.toggle(); editing.saveAndApply(); editing.stop()
  until({!editing.running}); runLoop(0.3)
  precondition(launches().count == beforeEdit + 1, "stop during settings reload restarted core")
  editing.shutdown()
  let watch = LinkModel(defaults: defaults, profile: root, engine: core, observeSystemEvents: false, hasDeviceControl: {true}, desktopState: {MacDesktopSnapshot(ready: true, signature: "fixture-display")}, foreignCore: {false}, recoveryDelay: 30, ipcPath: root.appendingPathComponent("socket").path, failureNotice: 0.3, failureEscalate: 0.6)
  watch.start(); until({watch.connected})
  let beforeFailure = launches().count
  try Data().write(to: root.appendingPathComponent("launches.linkfail"))
  until({watch.title == "无法连接所选设备"})
  runLoop(0.3)
  precondition(launches().count == beforeFailure && watch.running && !watch.connected && watch.failureRefreshes == 1)
  precondition(watch.logs.filter {$0.contains("连接失败开始")}.count == 1)
  precondition(watch.logs.filter {$0.contains("连接失败持续")}.count == 1)
  watch.observeDevice(PairedDevice(fingerprint: pin, name: "RenamedPeer", address: "127.0.0.2", platform: "Windows", role: "server", lastSeen: Date().timeIntervalSince1970))
  runLoop(0.2); precondition(launches().count == beforeFailure, "name change bypassed debounce")
  watch.observeDevice(PairedDevice(fingerprint: pin, name: "RenamedPeer", address: "127.0.0.3", platform: "Windows", role: "server", lastSeen: Date().timeIntervalSince1970))
  until({launches().count == beforeFailure + 1}, seconds: 1)
  precondition(watch.logs.contains {$0.contains("所选设备地址更新：127.0.0.2 → 127.0.0.3")})
  runLoop(1.5)
  try FileManager.default.removeItem(at: root.appendingPathComponent("launches.linkfail"))
  until({watch.connected && watch.title == "两台电脑已连接"})
  precondition(watch.logs.filter {$0.contains("连接恢复")}.count == 1)
  watch.stop(); until({!watch.running}); let refreshCount = watch.failureRefreshes
  for _ in 0..<100 { watch.networkSignal(); watch.resumeSignal() }
  watch.readLog("failed to connect to server\n"); runLoop(0.7)
  precondition(launches().count == beforeFailure + 1 && watch.failureRefreshes == refreshCount)
  watch.shutdown()
  let finalLaunchCount = launches().count
  defaults.set(true, forKey: "autoStartOnLaunch"); defaults.set(true, forKey: "lastSessionRequested")
  let queued = LinkModel(defaults: defaults, profile: root, engine: core, observeSystemEvents: false, hasDeviceControl: {true}, desktopState: {MacDesktopSnapshot(ready: true, signature: "fixture-display")}, foreignCore: {false}, recoveryDelay: 0.03)
  queued.beginAutomaticStart(); queued.stop(); runLoop(0.1); precondition(launches().count == finalLaunchCount && !defaults.bool(forKey:"lastSessionRequested"),"queued startup survived stop"); queued.shutdown()
  var stable=MacDesktopStability(); let now=Date(); let snapshot=MacDesktopSnapshot(ready:true,signature:"a")
  precondition(!stable.observe(snapshot,at:now)); precondition(stable.observe(snapshot,at:now.addingTimeInterval(5)))
  precondition(!stable.observe(MacDesktopSnapshot(ready:false,signature:""),at:now.addingTimeInterval(6)))
  precondition(!stable.observe(snapshot,at:now.addingTimeInterval(7)))
  print("Mac actual model checks passed: safe upgrade defaults, 100 network signals, healthy process retention, graceful endpoint reload, manual stop, no hung/crashed relaunch, queued startup cancellation and desktop stability.")
 }
}
