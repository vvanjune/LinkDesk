using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using LinkDesk;
class MultiPeerTests {
 static void Check(bool ok,string message){if(!ok)throw new Exception(message);}
 static PairedDevice Device(string pin,string address,string role="server",string platform="Windows")=>new(){Fingerprint=pin,Name="Same-Name",Address=address,Role=role,Platform=platform,LastSeen=DateTimeOffset.UtcNow.ToUnixTimeSeconds()};
 static async Task Main(string[] args) {
  var root=Path.Combine(Path.GetTempPath(),"linkdesk-peers-"+Guid.NewGuid());Directory.CreateDirectory(root);
  try {
   var own=Path.Combine(root,"own");var one=Path.Combine(root,"one");var two=Path.Combine(root,"two");
   LinkIdentity.Prepare(own);var pinA=PeerStore.Pin(LinkIdentity.Prepare(one))!;var pinB=PeerStore.Pin(LinkIdentity.Prepare(two))!;
   var old="v2:sha256:"+pinA+"\nv2:sha256:"+pinB+"\n";File.WriteAllText(Path.Combine(own,"tls","trusted-servers"),old);
   var store=new PeerStore(own);store.Migrate("Same-Name","192.0.2.10",false,new PeerInput{InvertVertical=true});
   Check(store.Devices.All(d=>d.Input?.InvertVertical==true),"ambiguous migration lost saved input");
   Check(store.Devices.Count()==2&&store.Selected is null,"ambiguous old trust auto-selected");
   store.Observe(Device(pinA,"192.0.2.10","server","macOS"));store.Observe(Device(pinB,"192.0.2.20"));
   store.Select(pinA);Check(store.Selected!.Id==pinA,"explicit selection lost");
   Check(!store.Observe(Device(pinB,"192.0.2.99")),"different paired same-name device treated as selected");
   Check(store.Selected!.Address=="192.0.2.10","different device changed selected address");
   Check(store.Observe(Device(pinA,"192.0.2.11","server","macOS")),"selected address migration ignored");
   Check(store.Selected!.Address=="192.0.2.11","legitimate address migration failed");
   store.Rename(pinA,"Work Mac");store.SetInput(new PeerInput{Command="ctrl",Control="super",InvertVertical=true,VerticalSpeed=1.4});
   var reloaded=new PeerStore(own);Check(reloaded.Selected!.Id==pinA&&reloaded.Selected.Alias=="Work Mac"&&reloaded.Selected.Input!.InvertVertical,"selected identity/input did not persist");
   var unknown=new string('c',64);store.Observe(Device(unknown,"192.0.2.30"));store.Save();Check(!File.ReadAllText(Path.Combine(own,"devices.json")).Contains(unknown),"unverified candidate persisted as trust");
   foreach(var source in new[]{"macOS","Windows"})foreach(var target in new[]{"macOS","Windows"})foreach(bool server in new[]{false,true}) {
    store.Observe(Device(pinA,"192.0.2.11",server?"client":"server",target));var scope=store.Session(server);
    foreach(var db in new[]{"trusted-clients","trusted-servers"})Check(File.ReadAllText(Path.Combine(scope,"tls",db))=="v2:sha256:"+pinA+"\n","TLS scope contains other trusted identity");
   }
   Check(File.ReadAllText(Path.Combine(own,"tls","trusted-servers"))==old,"historical trust overwritten");
   foreach(var role in new[]{"server","client"}){store.Observe(Device(pinA,"192.0.2.11",role));foreach(bool localServer in new[]{false,true})foreach(var name in new[]{"trusted-clients","trusted-servers"})Check(File.ReadAllText(Path.Combine(store.Session(localServer),"tls",name))=="v2:sha256:"+pinA+"\n","stale role blocked selected identity or broadened trust");}
   bool refused=false;
   store.Forget(pinA);Check(store.Selected is null&&!Directory.Exists(Path.Combine(own,"connections",pinA)),"forget did not revoke selection and TLS scope");
   try{store.Session(true);}catch(InvalidOperationException){refused=true;}Check(refused,"unselected identity allowed to connect");
   Check(new PeerStore(own).Selected is null,"forget selected another device on reload");
   File.Delete(Path.Combine(own,"devices.json"));var reset=new PeerStore(own);reset.Migrate("Same-Name","192.0.2.10",false,new PeerInput());Check(!reset.Devices.Any()&&reset.Selected is null,"forgotten legacy trust resurrected after catalog loss");
   File.WriteAllText(Path.Combine(own,"devices.json"),"invalid catalog");refused=false;try{_=new PeerStore(own);}catch(JsonException){refused=true;}Check(refused&&File.ReadAllText(Path.Combine(own,"devices.json"))=="invalid catalog","corrupt catalog silently replaced");
   using(var a=new DiscoveryResponder("Same-Name","server",Path.Combine(one,"tls","deskflow.pem"),24812))
   using(var b=new DiscoveryResponder("Same-Name","server",Path.Combine(two,"tls","deskflow.pem"),24813)) {
    var found=await DiscoveryClient.Probe(new[]{new IPEndPoint(IPAddress.Loopback,24812),new IPEndPoint(IPAddress.Loopback,24813)},"",CancellationToken.None);
    Check(found.Count==2&&found.All(d=>d.Name=="Same-Name")&&found.Select(d=>d.Id).Distinct().Count()==2,"same-name devices collapsed in discovery");
   }
   if(args.Length==2&&args[0]=="fixtures") {
    Directory.CreateDirectory(args[1]);File.Copy(Path.Combine(one,"tls","deskflow.pem"),Path.Combine(args[1],"one.pem"),true);File.Copy(Path.Combine(two,"tls","deskflow.pem"),Path.Combine(args[1],"two.pem"),true);
    Console.WriteLine("Test fixtures written to isolated folder.");
   }
   Console.WriteLine("Multi-peer checks passed: same-name identity separation, exact selection, trusted-peer substitution rejection, migration, per-device input, all role/platform scopes, corruption preservation and revocation.");
  }finally{Directory.Delete(root,true);}
 }
}
