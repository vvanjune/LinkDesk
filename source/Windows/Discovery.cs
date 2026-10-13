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
 public string platform {get;set;}="unknown";
 public string role {get;set;}="server";
 public string certificate {get;set;}="";
 public string signature {get;set;}="";
}
public static class DiscoveryVerifier {
 public static byte[] Message(DiscoveryOffer offer)=>Encoding.UTF8.GetBytes(offer.version==1?
  $"LinkDesk/1\n{offer.nonce}\n{offer.name}\n{offer.address}\n24800\n":
  $"LinkDesk/2\n{offer.nonce}\n{offer.name}\n{offer.address}\n24800\n{offer.platform}\n{offer.role}\n");
 public static PairedDevice? Authenticate(DiscoveryOffer offer,string nonce,IPAddress source) {
  try {
   if(offer.magic!="linkdesk-offer"||offer.version is not (1 or 2)||offer.nonce!=nonce||offer.port!=24800||
      !System.Text.RegularExpressions.Regex.IsMatch(offer.name,"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$")||
      !IPAddress.TryParse(offer.address,out var address)||address.AddressFamily!=AddressFamily.InterNetwork||!address.Equals(source)||
      offer.certificate.Length>6000||offer.signature.Length>1500)return null;
   if(offer.version==2&&(offer.platform is not ("macOS" or "Windows")||offer.role is not ("server" or "client")||
      !System.Text.RegularExpressions.Regex.IsMatch(nonce,"^[a-f0-9]{64}$")))return null;
   var raw=Convert.FromBase64String(offer.certificate);if(raw.Length>4096)return null;
   using var cert=X509CertificateLoader.LoadCertificate(raw);
   var signature=Convert.FromBase64String(offer.signature);var message=Message(offer);
   using var rsa=cert.GetRSAPublicKey();using var ec=cert.GetECDsaPublicKey();
   bool valid=rsa is not null?rsa.VerifyData(message,signature,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1):
    ec is not null&&ec.VerifyData(message,signature,HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence);
   if(!valid)return null;
   return new PairedDevice{Fingerprint=Convert.ToHexString(SHA256.HashData(raw)).ToLowerInvariant(),Name=offer.name,Address=offer.address,
    Platform=offer.version==2?offer.platform:"unknown",Role=offer.version==2?offer.role:"server",LastSeen=DateTimeOffset.UtcNow.ToUnixTimeSeconds()};
  }catch{return null;}
 }
 // Version 1 compatibility checks require exactly one selected pin; multi-pin inputs are rejected.
 // Applications use v2 Authenticate plus explicit per-device pairing and selection.
 public static bool Verify(DiscoveryOffer offer,string nonce,string peer,IPAddress source,IEnumerable<string> trusted) {
  var device=Authenticate(offer,nonce,source);
  var selected=trusted.Select(PeerStore.Pin).Where(p=>p is not null).Distinct().ToArray();
  return selected.Length==1&&device is not null&&device.Name==peer&&selected[0]==device.Fingerprint;
 }
}
public sealed class DiscoveryResponder : IDisposable {
 private readonly CancellationTokenSource cancellation=new();
 private readonly UdpClient udp;
 private readonly X509Certificate2 identity;
 public DiscoveryResponder(string name,string role,string pem,int port=24801) {
  identity=X509Certificate2.CreateFromPemFile(pem,pem);
  try{udp=new UdpClient(new IPEndPoint(IPAddress.Any,port));}catch{identity.Dispose();throw;}
  _=Serve(name,role,cancellation.Token);
 }
 private async Task Serve(string name,string role,CancellationToken token) {
  using var rsa=identity.GetRSAPrivateKey();using var ec=identity.GetECDsaPrivateKey();
  var recent=new Dictionary<IPAddress,DateTime>();var last=DateTime.MinValue;
  while(!token.IsCancellationRequested) {
   try {
    var packet=await udp.ReceiveAsync(token);if(packet.Buffer.Length>1024)continue;
    using var document=JsonDocument.Parse(packet.Buffer);var query=document.RootElement;
    if(!query.TryGetProperty("magic",out var magic)||magic.GetString()!="linkdesk-discover"||!query.TryGetProperty("version",out var version)||version.GetInt32()!=2||
       !query.TryGetProperty("nonce",out var challenge))continue;
    var nonce=challenge.GetString()??"";if(!System.Text.RegularExpressions.Regex.IsMatch(nonce,"^[a-f0-9]{64}$"))continue;
    var now=DateTime.UtcNow;var source=packet.RemoteEndPoint.Address;
    if((now-last).TotalMilliseconds<125||recent.TryGetValue(source,out var before)&&(now-before).TotalSeconds<1)continue;
    if(recent.Count>256)recent.Clear();recent[source]=now;last=now;
    using var route=new Socket(AddressFamily.InterNetwork,SocketType.Dgram,ProtocolType.Udp);route.Connect(packet.RemoteEndPoint);
    var address=((IPEndPoint)route.LocalEndPoint!).Address.ToString();
    var offer=new DiscoveryOffer{magic="linkdesk-offer",version=2,nonce=nonce,name=name,address=address,port=24800,platform="Windows",role=role,certificate=Convert.ToBase64String(identity.RawData)};
    var data=DiscoveryVerifier.Message(offer);
    var signature=rsa is not null?rsa.SignData(data,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1):ec!.SignData(data,HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence);
    offer.signature=Convert.ToBase64String(signature);
    await udp.SendAsync(JsonSerializer.SerializeToUtf8Bytes(offer),packet.RemoteEndPoint,token);
   }catch(OperationCanceledException){break;}catch(ObjectDisposedException){break;}catch(Exception){if(token.IsCancellationRequested)break;}
  }
  identity.Dispose();
 }
 public void Dispose(){cancellation.Cancel();udp.Dispose();}
}
public sealed class DiscoveryClient : IDisposable {
 private readonly CancellationTokenSource cancellation=new();
 private int refresh=1;
 public void Refresh()=>Interlocked.Exchange(ref refresh,1);
 public DiscoveryClient(string ownPin,Func<string> lastAddress,Action<PairedDevice> found,Action<string> status) {
  _=Run(ownPin,lastAddress,found,status,cancellation.Token);
 }
 public static async Task<List<PairedDevice>> Probe(IEnumerable<IPEndPoint> destinations,string ownPin,CancellationToken token) {
  using var udp=new UdpClient(AddressFamily.InterNetwork){EnableBroadcast=true};udp.Client.Bind(new IPEndPoint(IPAddress.Any,0));
  var nonce=Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
  var query=JsonSerializer.SerializeToUtf8Bytes(new{magic="linkdesk-discover",version=2,nonce,name=""});
  foreach(var destination in destinations.Distinct()){try{await udp.SendAsync(query,destination,token);}catch(SocketException){}}
  using var deadline=CancellationTokenSource.CreateLinkedTokenSource(token);deadline.CancelAfter(2200);
  var devices=new Dictionary<string,PairedDevice>();
  while(!deadline.IsCancellationRequested) {
   try {
    var response=await udp.ReceiveAsync(deadline.Token);if(response.Buffer.Length>8192)continue;
    var offer=JsonSerializer.Deserialize<DiscoveryOffer>(response.Buffer);
    if(offer is null||offer.version!=2)continue;
    var device=DiscoveryVerifier.Authenticate(offer,nonce,response.RemoteEndPoint.Address);
    if(device is not null&&device.Fingerprint!=ownPin&&devices.Count<128)devices[device.Id]=device;
   }catch(JsonException){}catch(OperationCanceledException){break;}
  }
  return devices.Values.ToList();
 }
 private async Task Run(string ownPin,Func<string> lastAddress,Action<PairedDevice> found,Action<string> status,CancellationToken token) {
  while(!token.IsCancellationRequested) {
   try {
    Interlocked.Exchange(ref refresh,0);
    var addresses=BroadcastAddresses().ToList();
    if(IPAddress.TryParse(lastAddress(),out var previous)&&previous.AddressFamily==AddressFamily.InterNetwork)addresses.Insert(0,previous);
    var devices=await Probe(addresses.Distinct().Select(a=>new IPEndPoint(a,24801)),ownPin,token);
    foreach(var device in devices)found(device);
    status($"局域网发现已开启 · 本轮发现 {devices.Count} 台电脑");
    var end=DateTime.UtcNow.AddMilliseconds(5000+Random.Shared.Next(1500));
    while(DateTime.UtcNow<end&&Volatile.Read(ref refresh)==0)await Task.Delay(150,token);
   }catch(OperationCanceledException){break;}catch(Exception){status("局域网发现暂不可用，可手动添加设备。");try{await Task.Delay(3000,token);}catch(OperationCanceledException){break;}}
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
