using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using LinkDesk;

class DiscoveryTests {
 static void Check(bool ok,string message){if(!ok)throw new Exception(message);}
 static byte[] Message(string nonce,string name,string address)=>Encoding.UTF8.GetBytes($"LinkDesk/1\n{nonce}\n{name}\n{address}\n24800\n");
 static async Task Main(string[] args){
  if(args.Length>0&&args[0]=="probe") {
   var address=IPAddress.Parse(args[1]);using var cert=X509Certificate2.CreateFromPemFile(args[2]);
   string pin="v2:sha256:"+Convert.ToHexString(SHA256.HashData(cert.RawData)).ToLowerInvariant();
   using var udp=new UdpClient(AddressFamily.InterNetwork);string nonce=Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
   var sent=await udp.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new{magic="linkdesk-discover",version=1,nonce,name="Mac-One"}),new IPEndPoint(address,24801));
   Console.WriteLine("Sent discovery query: "+sent+" bytes");
   using var deadline=new CancellationTokenSource(5000);var reply=await udp.ReceiveAsync(deadline.Token);
   var offer=JsonSerializer.Deserialize<DiscoveryOffer>(reply.Buffer)!;
   Check(DiscoveryVerifier.Verify(offer,nonce,"Mac-One",reply.RemoteEndPoint.Address,new[]{pin}),"Swift responder proof rejected");
   Console.WriteLine("Cross-language UDP discovery passed: "+offer.name+" @ "+offer.address);return;
  }
  using var rsa=RSA.Create(2048);var request=new CertificateRequest("CN=LinkDesk Test",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
  using var identity=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1),DateTimeOffset.UtcNow.AddDays(1));
  var raw=identity.Export(X509ContentType.Cert);var nonceText=new string('a',64);string peer="Mac-One",ip="192.0.2.10";
  var signature=rsa.SignData(Message(nonceText,peer,ip),HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
  var offerTest=new DiscoveryOffer{magic="linkdesk-offer",version=1,nonce=nonceText,name=peer,address=ip,port=24800,certificate=Convert.ToBase64String(raw),signature=Convert.ToBase64String(signature)};
  string trusted="v2:sha256:"+Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();var source=IPAddress.Parse(ip);
  Check(DiscoveryVerifier.Verify(offerTest,nonceText,peer,source,new[]{trusted}),"Valid offer rejected");
  Check(!DiscoveryVerifier.Verify(offerTest,new string('b',64),peer,source,new[]{trusted}),"Replay accepted");
  Check(!DiscoveryVerifier.Verify(offerTest,nonceText,"another-Mac",source,new[]{trusted}),"Wrong peer accepted");
  Check(!DiscoveryVerifier.Verify(offerTest,nonceText,peer,source,Array.Empty<string>()),"Untrusted identity accepted");
  Check(!DiscoveryVerifier.Verify(offerTest,nonceText,peer,IPAddress.Parse("192.0.2.11"),new[]{trusted}),"Relayed address accepted");
  offerTest.address="192.0.2.11";Check(!DiscoveryVerifier.Verify(offerTest,nonceText,peer,IPAddress.Parse(offerTest.address),new[]{trusted}),"Tampered signed address accepted");offerTest.address=ip;
  offerTest.address="192.0.2.11";offerTest.signature=Convert.ToBase64String(rsa.SignData(Message(nonceText,peer,offerTest.address),HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1));
  Check(DiscoveryVerifier.Verify(offerTest,nonceText,peer,IPAddress.Parse(offerTest.address),new[]{trusted}),"Legitimate address migration rejected");offerTest.address=ip;
  offerTest.signature=Convert.ToBase64String(new byte[256]);Check(!DiscoveryVerifier.Verify(offerTest,nonceText,peer,source,new[]{trusted}),"Forged signature accepted");
  if(args.Length==2&&args[0]=="fixture"){Directory.CreateDirectory(args[1]);File.WriteAllText(Path.Combine(args[1],"identity.pem"),identity.ExportCertificatePem()+"\n"+rsa.ExportPkcs8PrivateKeyPem());}
  Console.WriteLine("Discovery identity checks passed: trusted pin, fresh nonce, name, endpoint, tamper and signature rejection.");
 }
}
