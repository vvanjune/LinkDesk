import Foundation
@main struct ConfigurationTests {
 static func main() throws {
  precondition(LinkConfiguration.validName("Mac-One"))
  precondition(LinkConfiguration.validName("Windows-One"))
  precondition(!LinkConfiguration.validName("Mac\n[security]"))
  precondition(!LinkConfiguration.validHost("1.2.3.4\nport=5"))
  precondition(LinkConfiguration.fingerprintLine(String(repeating:"AA:",count:31)+"AA") == "v2:sha256:"+String(repeating:"aa",count:32))
  precondition(LinkConfiguration.fingerprintLine("00:01") == nil)
  let path="/Users/a folder/Library/Deskflow/linkdesk-server.conf"
  let config=try LinkConfiguration.settings(local:"Mac",peer:"Windows",server:true,host:"",layout:"down",configPath:path)
  precondition(config.contains("macWakeDisplayOnRemoteInput=false")); precondition(config.contains("macScreenSaverSync=false")); precondition(config.contains("preventSleep=false"));
  let wake = try LinkConfiguration.settings(local:"Mac",peer:"Windows",server:false,host:"192.0.2.10",layout:"right",configPath:path,wakeDisplay:true); precondition(wake.contains("macWakeDisplayOnRemoteInput=true"));
  precondition(config.contains("tlsEnabled=true")); precondition(config.contains("checkPeerFingerprints=true"));precondition(config.contains(path))
  let links=LinkConfiguration.links(local:"Mac",peer:"Windows",layout:"down")
  precondition(links.contains("down = Windows"));precondition(links.contains("up = Mac"));precondition(!links.contains("keystroke"))
  do { _=try LinkConfiguration.settings(local:"Mac",peer:"Mac",server:true,host:"",layout:"right",configPath:path); fatalError("duplicate names accepted") } catch {}
  let input=LinkInputSettings(command:"ctrl",control:"super",invertVertical:true,verticalSpeed:1.3)
  let mapped=try LinkConfiguration.settings(local:"Mac",peer:"Windows",server:true,host:"",layout:"right",configPath:path,input:input)
  precondition(mapped.contains("[computer_Windows]\nname=Windows\nmodifierSuper=ctrl\nmodifierMeta=ctrl\nmodifierCtrl=super"))
  precondition(mapped.contains("invertYScroll=true"));precondition(mapped.contains("invertXScroll=false"));precondition(mapped.contains("yScrollScale=1.3"))
  let receiver=try LinkConfiguration.settings(local:"Windows",peer:"Mac",server:false,host:"192.0.2.10",layout:"right",configPath:path,input:input)
  precondition(!receiver.contains("modifierSuper="));precondition(receiver.contains("invertYScroll=true"))
  let delayed=try LinkConfiguration.settings(local:"Mac",peer:"Windows",server:true,host:"",layout:"right",configPath:path,switchDelay:250)
  precondition(delayed.contains("enableSwitchDelay=true\nswitchDelay=250"))
  let instant=try LinkConfiguration.settings(local:"Mac",peer:"Windows",server:true,host:"",layout:"right",configPath:path,switchDelay:0)
  precondition(!instant.contains("enableSwitchDelay"))
  let receiverDelay=try LinkConfiguration.settings(local:"Windows",peer:"Mac",server:false,host:"192.0.2.10",layout:"right",configPath:path,switchDelay:250)
  precondition(!receiverDelay.contains("enableSwitchDelay"))
  do { _=try LinkConfiguration.settings(local:"Mac",peer:"Windows",server:true,host:"",layout:"right",configPath:path,switchDelay:9000); fatalError("invalid switch delay accepted") } catch {}
  precondition(LinkConfiguration.refusalMessage("UnknownClient").contains("配对"))
  precondition(LinkConfiguration.refusalMessage("AlreadyConnected").contains("同名"))
  precondition(LinkConfiguration.refusalMessage("WeirdReason").contains("WeirdReason"))
  for bad in [LinkInputSettings(command:"ctrl\n[security]"),LinkInputSettings(verticalSpeed:Double.nan),LinkInputSettings(horizontalSpeed:0)] {
   do { _=try LinkConfiguration.settings(local:"Mac",peer:"Windows",server:true,host:"",layout:"right",configPath:path,input:bad);fatalError("invalid input settings accepted") } catch {}
  }
  print("Configuration checks passed: injection, names, layout, TLS, fingerprints, peer-only mapping, scroll direction/speed.")
 }
}
