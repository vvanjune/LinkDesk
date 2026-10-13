using System;
using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LinkDesk;
public static class IdentityTests {
 static void Check(bool ok,string message){if(!ok)throw new Exception(message);}
 public static void Main(string[] args) {
  var root=Path.Combine(Path.GetTempPath(),"linkdesk-identity-"+Guid.NewGuid());
  try {
   var original=Path.Combine(root,"original");var pin=LinkIdentity.Prepare(original);
   var identity=Path.Combine(original,"tls","deskflow.pem");var bytes=File.ReadAllBytes(identity);
   Check(pin.Length==95,"invalid fingerprint");
   Check(LinkIdentity.Prepare(original)==pin&&Convert.ToBase64String(File.ReadAllBytes(identity))==Convert.ToBase64String(bytes),"identity rotated on restart");
   File.WriteAllText(Path.Combine(original,"tls","trusted-servers"),"v2:sha256:test-only\n");
   var migrated=Path.Combine(root,"migrated");
   Check(LinkIdentity.Prepare(migrated,Path.Combine(original,"tls"))==pin,"migration changed identity");
   Check(File.ReadAllText(Path.Combine(migrated,"tls","trusted-servers"))=="v2:sha256:test-only\n","pairing lost");
   var broken=Path.Combine(root,"broken");Directory.CreateDirectory(Path.Combine(broken,"tls"));
   var bad=Path.Combine(broken,"tls","deskflow.pem");File.WriteAllText(bad,"invalid identity");
   bool refused=false;try{LinkIdentity.Prepare(broken);}catch(CryptographicException){refused=true;}
   Check(refused&&File.ReadAllText(bad)=="invalid identity","corrupt identity overwritten");
   using var cert=X509Certificate2.CreateFromPemFile(identity,identity);
   using var rsa=cert.GetRSAPrivateKey()!;
   const string nonce="fresh-test-nonce",peer="Mac",address="127.0.0.1";
   var offer=new DiscoveryOffer{magic="linkdesk-offer",version=1,nonce=nonce,name=peer,address=address,port=24800,certificate=Convert.ToBase64String(cert.RawData)};
   offer.signature=Convert.ToBase64String(rsa.SignData(System.Text.Encoding.UTF8.GetBytes($"LinkDesk/1\n{nonce}\n{peer}\n{address}\n24800\n"),HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1));
   Check(DiscoveryVerifier.Verify(offer,nonce,peer,System.Net.IPAddress.Loopback,new[]{"v2:sha256:"+pin.Replace(":","").ToLowerInvariant()}),"new identity cannot authenticate discovery");
   if(args.Length==1){Directory.CreateDirectory(args[0]);File.Copy(identity,Path.Combine(args[0],"windows-test.pem"),true);File.WriteAllText(Path.Combine(args[0],"fingerprint.txt"),pin);}
   Console.WriteLine("Windows identity checks passed: fresh generation, stable reuse, migration, corruption preservation and signed discovery.");
  }finally{Directory.Delete(root,true);}
 }
}
