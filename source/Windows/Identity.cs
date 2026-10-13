using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LinkDesk;
public static class LinkIdentity {
 public static string Fingerprint(string pem) {
  using var cert=X509Certificate2.CreateFromPemFile(pem,pem);
  // CreateFromPemFile also verifies that the certificate matches its private key.
  return string.Join(":",Convert.ToHexString(SHA256.HashData(cert.RawData)).Chunk(2).Select(pair=>new string(pair)));
 }
 public static string Prepare(string profile,string? legacy=null) {
  var tls=Path.Combine(profile,"tls");Directory.CreateDirectory(tls);
  var identity=Path.Combine(tls,"deskflow.pem");
  if(!File.Exists(identity)) {
   var candidate=Path.Combine(tls,Guid.NewGuid().ToString("N")+".tmp");
   try {
    if(legacy is not null&&File.Exists(Path.Combine(legacy,"deskflow.pem"))) {
     File.Copy(Path.Combine(legacy,"deskflow.pem"),candidate);
     _=Fingerprint(candidate);
     foreach(var name in new[]{"trusted-clients","trusted-servers"}) {
      var old=Path.Combine(legacy,name);var destination=Path.Combine(tls,name);
      if(File.Exists(old)&&!File.Exists(destination))File.Copy(old,destination);
     }
    }else {
     using var rsa=RSA.Create(2048);
     var request=new CertificateRequest("CN=LinkDesk",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
     request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false,false,0,true));
     request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature|X509KeyUsageFlags.KeyEncipherment,true));
     using var cert=request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5),DateTimeOffset.UtcNow.AddYears(10));
     File.WriteAllText(candidate,rsa.ExportRSAPrivateKeyPem()+"\n"+cert.ExportCertificatePem()+"\n");
     _=Fingerprint(candidate);
    }
    File.Move(candidate,identity);
   }finally{if(File.Exists(candidate))File.Delete(candidate);}
  }
  return Fingerprint(identity);
 }
}
