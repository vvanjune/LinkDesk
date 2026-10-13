using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace LinkDesk;
public sealed class DiscoveryOffer {
 public string magic {get;set;}="";
 public int version {get;set;}
 public string nonce {get;set;}="";
 public string name {get;set;}="";
 public string address {get;set;}="";
 public int port {get;set;}
 public string certificate {get;set;}="";
 public string signature {get;set;}="";
}
public static class DiscoveryVerifier {
 public static bool Verify(DiscoveryOffer offer,string nonce,string peer,IPAddress source,IEnumerable<string> trusted) {
  try {
   if(offer.magic!="linkdesk-offer"||offer.version!=1||offer.nonce!=nonce||offer.name!=peer||offer.port!=24800||
      !IPAddress.TryParse(offer.address,out var address)||address.AddressFamily!=AddressFamily.InterNetwork||!address.Equals(source)||
      offer.certificate.Length>6000||offer.signature.Length>1500)return false;
   var raw=Convert.FromBase64String(offer.certificate);
   var pin="v2:sha256:"+Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant();
   if(!trusted.Any(line=>string.Equals(line.Trim(),pin,StringComparison.OrdinalIgnoreCase)))return false;
   using var cert=X509CertificateLoader.LoadCertificate(raw);
   var message=Encoding.UTF8.GetBytes($"LinkDesk/1\n{nonce}\n{peer}\n{offer.address}\n24800\n");
   var signature=Convert.FromBase64String(offer.signature);
   using var rsa=cert.GetRSAPublicKey();
   if(rsa is not null)return rsa.VerifyData(message,signature,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
   using var ec=cert.GetECDsaPublicKey();
   return ec is not null&&ec.VerifyData(message,signature,HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence);
  }catch{return false;}
 }
}
public sealed class DiscoveryClient : IDisposable {
 private readonly CancellationTokenSource cancellation=new();
 private int refresh=1;
 public void Refresh()=>Interlocked.Exchange(ref refresh,1);
 public DiscoveryClient(string peer,string database,Func<string> lastAddress,Func<bool> connected,Action<string> found,Action<string> status) {
  _=Run(peer,database,lastAddress,connected,found,status,cancellation.Token);
 }
 private async Task Run(string peer,string database,Func<string> lastAddress,Func<bool> connected,Action<string> found,Action<string> status,CancellationToken token) {
  var next=DateTime.MinValue;
  while(!token.IsCancellationRequested) {
   try {
    if(Interlocked.Exchange(ref refresh,0)==1||DateTime.UtcNow>=next) {
     next=DateTime.UtcNow.AddSeconds(connected()?20:6);
     var trusted=File.Exists(database)?File.ReadAllLines(database):Array.Empty<string>();
     if(!trusted.Any(s=>s.StartsWith("v2:sha256:")))status("首次连接请填写 Mac 显示的地址，再点击“启动共享”并核对指纹。");
     else {
      using var udp=new UdpClient(AddressFamily.InterNetwork){EnableBroadcast=true};
      udp.Client.Bind(new IPEndPoint(IPAddress.Any,0));
      var nonce=Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
      var query=JsonSerializer.SerializeToUtf8Bytes(new{magic="linkdesk-discover",version=1,nonce,name=peer});
      var candidates=BroadcastAddresses().ToList();
      if(IPAddress.TryParse(lastAddress(),out var previous)&&previous.AddressFamily==AddressFamily.InterNetwork)candidates.Insert(0,previous);
      var destinations=candidates.Distinct().ToArray();
      foreach(var destination in destinations){try{await udp.SendAsync(query,new IPEndPoint(destination,24801),token);}catch(SocketException){}}
      using var probe=CancellationTokenSource.CreateLinkedTokenSource(token);probe.CancelAfter(3000);
      bool accepted=false;
      while(!probe.IsCancellationRequested){
       try {
        var response=await udp.ReceiveAsync(probe.Token);
        if(response.Buffer.Length>8192)continue;
        var offer=JsonSerializer.Deserialize<DiscoveryOffer>(response.Buffer);
        if(offer is not null&&DiscoveryVerifier.Verify(offer,nonce,peer,response.RemoteEndPoint.Address,trusted)){
         found(offer.address);status("已自动找到已配对的 Mac");accepted=true;break;
        }
       }catch(JsonException){continue;}catch(OperationCanceledException){break;}
      }
      if(!accepted&&!connected())status("正在查找已配对的 Mac；同时尝试上次地址。");
     }
    }
    await Task.Delay(1000,token);
   }catch(OperationCanceledException){break;}catch(Exception){status("自动查找暂不可用，可切换为手动 IP。");try{await Task.Delay(3000,token);}catch(OperationCanceledException){break;}}
  }
 }
 private static IEnumerable<IPAddress> BroadcastAddresses() {
  foreach(var adapter in NetworkInterface.GetAllNetworkInterfaces().Where(n=>n.OperationalStatus==OperationalStatus.Up))
   foreach(var entry in adapter.GetIPProperties().UnicastAddresses.Where(a=>a.Address.AddressFamily==AddressFamily.InterNetwork&&!IPAddress.IsLoopback(a.Address))) {
    var ip=entry.Address.GetAddressBytes();var mask=entry.IPv4Mask.GetAddressBytes();
    if(ip.Length==4&&mask.Length==4&&mask.Any(b=>b!=0))yield return new IPAddress(ip.Zip(mask,(a,m)=>(byte)(a|~m)).ToArray());
   }
  yield return IPAddress.Broadcast;
 }
 public void Dispose(){cancellation.Cancel();}
}
