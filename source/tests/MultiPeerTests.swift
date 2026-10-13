import Foundation
@main struct MultiPeerTests {
 static func check(_ value: Bool, _ message: String) { precondition(value, message) }
 static func main() throws {
  let fm=FileManager.default, root=fm.temporaryDirectory.appendingPathComponent("linkdesk-peers-"+UUID().uuidString)
  defer { try? fm.removeItem(at: root) }
  let own=root.appendingPathComponent("own"), one=root.appendingPathComponent("one"), two=root.appendingPathComponent("two")
  _=try LinkIdentity.prepare(at: own)
  let a=PeerStore.pin(try LinkIdentity.prepare(at: one))!, b=PeerStore.pin(try LinkIdentity.prepare(at: two))!
  let old="v2:sha256:\(a)\nv2:sha256:\(b)\n"
  try old.write(to: own.appendingPathComponent("tls/trusted-servers"), atomically: true, encoding: .utf8)
  let store=try PeerStore(profile:own);try store.migrate(name:"Same-Name",address:"192.0.2.10",server:false,input:LinkInputSettings(invertVertical:true))
  check(store.devices.allSatisfy { $0.input?.invertVertical == true },"ambiguous migration lost saved input")
  check(store.devices.count==2 && store.selected==nil,"ambiguous old trust auto-selected")
  func device(_ pin:String,_ address:String,_ role:String="server",_ platform:String="macOS")->PairedDevice { PairedDevice(fingerprint:pin,name:"Same-Name",address:address,platform:platform,role:role,lastSeen:Date().timeIntervalSince1970) }
  _=try store.observe(device(a,"192.0.2.10"));_=try store.observe(device(b,"192.0.2.20"));try store.select(a)
  check(!(try store.observe(device(b,"192.0.2.99"))),"different trusted same-name device considered selected")
  check(store.selected?.address=="192.0.2.10","unselected identity changed chosen address")
  check(try store.observe(device(a,"192.0.2.11")),"legitimate selected migration ignored")
  try store.rename(a,alias:"Work Mac");try store.setInput(LinkInputSettings(command:"ctrl",control:"super",invertVertical:true))
  let loaded=try PeerStore(profile:own);check(loaded.selected?.id==a && loaded.selected?.alias=="Work Mac" && loaded.selected?.input?.invertVertical==true,"selection/input persistence failed")
  let unknown=String(repeating:"c",count:64);_=try store.observe(device(unknown,"192.0.2.30"));try store.save()
  check(!(try String(contentsOf:own.appendingPathComponent("devices.json"),encoding:.utf8)).contains(unknown),"unpaired candidate persisted as trust")
  for source in ["macOS","Windows"] { for target in ["macOS","Windows"] { for server in [false,true] {
   _=try store.observe(device(a,"192.0.2.11",server ? "client":"server",target));let folder=try store.session(server:server)
   for name in ["trusted-clients","trusted-servers"] { check(try String(contentsOf:folder.appendingPathComponent("tls/\(name)"),encoding:.utf8)=="v2:sha256:\(a)\n","TLS scope admitted a different trusted peer") }
   let input=source==target ? LinkInputSettings():LinkInputSettings.macToWindows
   let text=try LinkConfiguration.settings(local:source+"-Source",peer:target+"-Target",server:server,host:"192.0.2.11",layout:"left",configPath:folder.appendingPathComponent("server.conf").path,input:input)
   check(text.contains("tlsEnabled=true") && text.contains("checkPeerFingerprints=true") && text.contains("coreMode=\(server ? 2:1)"),"platform/role config failed")
  } } }
  check(try String(contentsOf:own.appendingPathComponent("tls/trusted-servers"),encoding:.utf8)==old,"old trust overwritten")
  _=try store.observe(device(a,"192.0.2.11","client"))
  do { _=try store.session(server:false);fatalError("same-role session permitted") } catch {}
  try store.forget(a);check(store.selected==nil && !fm.fileExists(atPath:own.appendingPathComponent("connections/\(a)").path),"forget did not revoke TLS scope")
  try fm.removeItem(at:own.appendingPathComponent("devices.json"));let reset=try PeerStore(profile:own);try reset.migrate(name:"Same-Name",address:"192.0.2.10",server:false,input:LinkInputSettings());check(reset.devices.isEmpty && reset.selected==nil,"revoked legacy trust resurrected")
  try "invalid catalog".write(to:own.appendingPathComponent("devices.json"),atomically:true,encoding:.utf8)
  do { _=try PeerStore(profile:own);fatalError("invalid book silently replaced") } catch {}
  print("Mac multi-peer checks passed: same-name identities, exact selection, migration, per-device input, four OS combinations and both roles, pinned TLS scopes, corruption protection and revocation.")
 }
}
