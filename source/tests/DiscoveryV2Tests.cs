using System;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
using System.Threading.Tasks;
using LinkDesk;
class DiscoveryV2Tests {
 static void Check(bool value,string message){if(!value)throw new Exception(message);}
 static async Task Main(string[] args) {
  if(args.Length==3&&args[0]=="serve") {
   using var a=new DiscoveryResponder("Same-Name","client",args[1],24812);
   using var b=new DiscoveryResponder("Same-Name","server",args[2],24813);
   Console.WriteLine("Windows discovery test endpoints ready: client 24812, server 24813.");await Task.Delay(20000);return;
  }
  if(args.Length==2&&args[0]=="probe") {
   var peers=await DiscoveryClient.Probe(new[]{new IPEndPoint(IPAddress.Loopback,int.Parse(args[1]))},"",CancellationToken.None);
   Check(peers.Count==1&&peers[0].Name=="Same-Name"&&peers[0].Platform=="macOS"&&peers[0].Role=="client","Swift advertisement rejected");
   Console.WriteLine("C# browser verified Swift client advertisement.");return;
  }
  using var rsa=RSA.Create(2048);var request=new CertificateRequest("CN=LinkDesk v2 test",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
  using var cert=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1),DateTimeOffset.UtcNow.AddDays(1));
  const string address="127.0.0.1";var nonce=new string('a',64);
  var offer=new DiscoveryOffer{magic="linkdesk-offer",version=2,nonce=nonce,name="Same-Name",address=address,port=24800,platform="Windows",role="server",certificate=Convert.ToBase64String(cert.RawData)};
  void Sign()=>offer.signature=Convert.ToBase64String(rsa.SignData(DiscoveryVerifier.Message(offer),HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1));
  foreach(var platform in new[]{"Windows","macOS"})foreach(var role in new[]{"client","server"}){offer.platform=platform;offer.role=role;Sign();Check(DiscoveryVerifier.Authenticate(offer,nonce,IPAddress.Loopback)?.Role==role,"platform/role proof rejected");}
  offer.platform="Windows";offer.role="server";Sign();
  var chosen=DiscoveryVerifier.Authenticate(offer,nonce,IPAddress.Loopback)!.Fingerprint;
  Check(!DiscoveryVerifier.Verify(offer,nonce,offer.name,IPAddress.Loopback,new[]{chosen,new string('b',64)}),"multi-pin fallback accepted");
  Check(DiscoveryVerifier.Authenticate(offer,new string('b',64),IPAddress.Loopback) is null,"replay accepted");
  offer.role="client";Check(DiscoveryVerifier.Authenticate(offer,nonce,IPAddress.Loopback) is null,"tampered role accepted");offer.role="server";
  offer.platform="macOS";Check(DiscoveryVerifier.Authenticate(offer,nonce,IPAddress.Loopback) is null,"tampered platform accepted");offer.platform="Windows";
  offer.name="Other-Name";Check(DiscoveryVerifier.Authenticate(offer,nonce,IPAddress.Loopback) is null,"tampered name accepted");offer.name="Same-Name";
  Check(DiscoveryVerifier.Authenticate(offer,nonce,IPAddress.Parse("127.0.0.2")) is null,"forwarded source accepted");
  offer.signature=Convert.ToBase64String(new byte[256]);Check(DiscoveryVerifier.Authenticate(offer,nonce,IPAddress.Loopback) is null,"forged signature accepted");
  Console.WriteLine("Discovery v2 checks passed: signed OS/role/name, current nonce, source address and forgery rejection.");
 }
}
