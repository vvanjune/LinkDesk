import Foundation
import CryptoKit
@main struct DiscoveryV2Tests {
 static func check(_ value:Bool,_ message:String){precondition(value,message)}
 static func main() throws {
  let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("linkdesk-v2-"+UUID().uuidString)
  defer{try? fm.removeItem(at:root)}
  _=try LinkIdentity.prepare(at:root);let pem=root.appendingPathComponent("tls/deskflow.pem")
  let cert=try LinkIdentity.openssl(["x509","-in",pem.path,"-outform","DER"])
  let nonce=String(repeating:"a",count:64),name="Same-Name",address="127.0.0.1"
  func signed(_ platform:String,_ role:String)throws->DiscoveryOffer {
   let data=DiscoveryOffer.signedMessage(nonce:nonce,name:name,address:address,platform:platform,role:role,version:2)
   let file=root.appendingPathComponent("message");try data.write(to:file)
   let signature=try LinkIdentity.openssl(["dgst","-sha256","-sign",pem.path,file.path])
   return DiscoveryOffer(nonce:nonce,name:name,address:address,platform:platform,role:role,certificate:cert.base64EncodedString(),signature:signature.base64EncodedString())
  }
  for platform in ["macOS","Windows"] {for role in ["server","client"] {let offer=try signed(platform,role);check(DiscoveryVerifier.authenticate(offer,nonce:nonce,source:address)?.role==role,"valid OS/role rejected")}}
  var offer=try signed("macOS","server")
  check(DiscoveryVerifier.authenticate(offer,nonce:String(repeating:"b",count:64),source:address)==nil,"replay accepted")
  offer.role="client";check(DiscoveryVerifier.authenticate(offer,nonce:nonce,source:address)==nil,"tampered role accepted");offer.role="server"
  offer.platform="Windows";check(DiscoveryVerifier.authenticate(offer,nonce:nonce,source:address)==nil,"tampered OS accepted");offer.platform="macOS"
  check(DiscoveryVerifier.authenticate(offer,nonce:nonce,source:"127.0.0.2")==nil,"forwarded address accepted")
  offer=DiscoveryOffer(nonce:nonce,name:name,address:address,certificate:cert.base64EncodedString(),signature:Data(repeating:0,count:256).base64EncodedString())
  check(DiscoveryVerifier.authenticate(offer,nonce:nonce,source:address)==nil,"forged signature accepted")
  if CommandLine.arguments.count==2&&CommandLine.arguments[1]=="cross" {
   let client=DiscoveryClient.probe(addresses:["127.0.0.1"],ownPin:"",port:24812)
   let server=DiscoveryClient.probe(addresses:["127.0.0.1"],ownPin:"",port:24813)
   check(client.count==1&&client[0].platform=="Windows"&&client[0].role=="client","C# client advertisement rejected")
   check(server.count==1&&server[0].platform=="Windows"&&server[0].role=="server","C# server advertisement rejected")
   print("Swift browser verified Windows client and server advertisements.")
  }
  if CommandLine.arguments.count==2&&CommandLine.arguments[1]=="serve" {
   let responder=DiscoveryResponder();check(responder.start(name:name,identity:pem,role:"client",port:24811),"responder failed")
   print("Mac discovery test endpoint ready: client 24811.");fflush(stdout);Thread.sleep(forTimeInterval:20);responder.stop()
  }
  print("Swift v2 discovery checks passed: signed OS/role, nonce/source validation and forged-signature rejection.")
 }
}
