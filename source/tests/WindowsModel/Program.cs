using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using LinkDesk;
class Program {
 static void Check(bool value,string reason){if(!value)throw new Exception(reason);}
 static string trace="";
 static int[] Launches()=>File.Exists(trace)?File.ReadAllLines(trace).Select(int.Parse).ToArray():Array.Empty<int>();
 static async Task Until(Func<bool> done,int timeout=9000){var timer=Stopwatch.StartNew();while(!done()){if(timer.ElapsedMilliseconds>timeout)throw new Exception("Timed out waiting for model state");await Task.Delay(50);}}
 [STAThread] static int Main(string[] args){
  var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};int result=1;
  app.Dispatcher.BeginInvoke(async ()=>{try{await Run(args[0]);Console.WriteLine("Windows model integration checks passed.");result=0;}catch(Exception e){Console.Error.WriteLine(e);}finally{app.Shutdown();}});
  app.Run();return result;
 }
 static async Task Run(string core){
  var root=Path.Combine(Path.GetTempPath(),"LinkDeskModelTests-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
  trace=Path.Combine(root,"launches");Environment.SetEnvironmentVariable("LINKDESK_TEST_TRACE",trace);
  var profile=Path.Combine(root,"profile");Directory.CreateDirectory(profile);
  File.WriteAllText(Path.Combine(profile,"preferences.json"),JsonSerializer.Serialize(new Preferences{LocalName="FixtureReceiver",AutoConnect=true,AutoDiscover=false}));
  var pin=new string('a',64);var store=new PeerStore(profile);store.Observe(new PairedDevice{Fingerprint=pin,Name="FixtureSender",Address="127.0.0.1",Role="server",Platform="Windows"});store.Pair(pin);
  var engine=Path.GetDirectoryName(Path.GetFullPath(core))!;Directory.CreateDirectory(Path.Combine(engine,"settings"));File.WriteAllText(Path.Combine(engine,"settings/Deskflow.conf"),"; test fixture\n");
  File.WriteAllText(Path.Combine(engine,"linkdesk-core.json"),JsonSerializer.Serialize(new {displaySafetyVersion=1,sha256=Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(core))).ToLowerInvariant()}));
  using var model=new LinkModel(profile,Path.GetFullPath(core),false,()=>new(true,"fixture-display"),TimeSpan.FromMilliseconds(30));
  try{
   model.BeginAutomaticStart();for(int i=0;i<100;i++)model.NetworkSignal();model.ResumeSignal();await Task.Delay(250);
   Check(Launches().Length==0&&!model.Running,"legacy AutoConnect started a stopped session");
   // Persist an explicitly requested previous session, then cancel queued startup.
   model.Start();await Until(()=>model.Connected);Check(Launches().Length==1,"manual start did not create exactly one core");
   int pid=Launches()[0];for(int i=0;i<100;i++)model.NetworkSignal();model.ResumeSignal();await Task.Delay(500);
   Check(Launches().Length==1&&!Process.GetProcessById(pid).HasExited,"healthy resume/network burst restarted core");
   model.SelectedDevice!.Address="127.0.0.2";model.Host="127.0.0.2";for(int i=0;i<100;i++)model.NetworkSignal();await Until(()=>Launches().Length==2&&model.Connected);
   Check(Process.GetProcessesByName("deskflow-core").Length==1,"endpoint reload left duplicate core processes");
   model.Stop();await Until(()=>!model.Running);for(int i=0;i<100;i++)model.NetworkSignal();model.ResumeSignal();await Task.Delay(300);
   Check(Launches().Length==2,"manual stop was undone by network/resume");
   model.Start();await Until(()=>model.Connected);File.WriteAllText(trace+".hold","");model.ResumeSignal();await Until(()=>model.Status=="共享核心暂未响应",5000);
   Check(Launches().Length==3&&Process.GetProcessesByName("deskflow-core").Length==1,"unresponsive core killed/restarted automatically");
   File.Delete(trace+".hold");model.Stop();await Until(()=>!model.Running);
   model.Start();await Until(()=>model.Connected);File.WriteAllText(trace+".crash","");model.NetworkSignal();await Until(()=>!model.Running);await Task.Delay(400);model.ResumeSignal();model.NetworkSignal();await Task.Delay(400);
   Check(Launches().Length==4,"crashed core was automatically relaunched");File.Delete(trace+".crash");
   model.Start();await Until(()=>model.Connected);
   int beforeEdit=Launches().Length;
   model.InvertVertical=!model.InvertVertical;model.SaveAndApply();
   await Until(()=>Launches().Length==beforeEdit+1&&model.Connected);
   model.SaveAndApply();await Task.Delay(200);
   Check(Launches().Length==beforeEdit+1,"unchanged settings reloaded core");
   model.InvertVertical=!model.InvertVertical;model.SaveAndApply();model.Stop();
   await Until(()=>!model.Running);await Task.Delay(300);
   Check(Launches().Length==beforeEdit+1,"stop during settings reload restarted core");
   using(var watch=new LinkModel(profile,Path.GetFullPath(core),false,()=>new(true,"fixture-display"),TimeSpan.FromSeconds(30),TimeSpan.FromMilliseconds(300),TimeSpan.FromMilliseconds(600))){
    watch.Start();await Until(()=>watch.Connected);int beforeFailure=Launches().Length;
    File.WriteAllText(trace+".linkfail","");await Until(()=>watch.Status=="无法连接所选设备");await Task.Delay(300);
    Check(Launches().Length==beforeFailure&&watch.Running&&!watch.Connected&&watch.FailureRefreshes==1,"watchdog restarted core or failed to refresh");
    Check(watch.Logs.Count(x=>x.Contains("连接失败开始"))==1&&watch.Logs.Count(x=>x.Contains("连接失败持续"))==1,"failure logs repeated");
    watch.ObserveDiscovered(new PairedDevice{Fingerprint=pin,Name="RenamedPeer",Address="127.0.0.2",Role="server",Platform="Windows"});
    await Task.Delay(200);Check(Launches().Length==beforeFailure,"name change bypassed debounce");
    watch.ObserveDiscovered(new PairedDevice{Fingerprint=pin,Name="RenamedPeer",Address="127.0.0.3",Role="server",Platform="Windows"});
    await Until(()=>Launches().Length==beforeFailure+1,1000);
    Check(watch.Logs.Any(x=>x.Contains("所选设备地址更新：127.0.0.2 → 127.0.0.3")),"address log missing");
    await Task.Delay(1500);File.Delete(trace+".linkfail");await Until(()=>watch.Connected&&watch.Status=="两台电脑已连接");
    Check(watch.Logs.Count(x=>x.Contains("连接恢复"))==1,"recovery log missing/repeated");
    watch.Stop();await Until(()=>!watch.Running);int refreshCount=watch.FailureRefreshes;
    for(int i=0;i<100;i++){watch.NetworkSignal();watch.ResumeSignal();}await Task.Delay(700);
    Check(Launches().Length==beforeFailure+1&&watch.FailureRefreshes==refreshCount,"stopped watchdog resurrected session");
   }
   bool desktopReady=true;
   using(var race=new LinkModel(profile,Path.GetFullPath(core),false,()=>new(desktopReady,"fixture-display"),TimeSpan.FromMilliseconds(30),TimeSpan.FromMilliseconds(100),TimeSpan.FromMilliseconds(200))){
    race.Start();await Until(()=>race.Connected);
    race.Handle("connectedClients=");Check(race.Connected,"server-only IPC cleared receiver state");
    race.Handle("connectionState=Disconnected");race.ObserveConnectionOutput("connected to secure socket");Check(!race.Connected,"TLS transport reported sharing connected");race.Handle("connectionState=Connected");
    race.ObserveConnectionOutput("failed to connect to server: Connection refused");race.Handle("connectionRefused=incompatible");var refusal=race.Detail;
    race.Handle("connectionState=Disconnected");await Task.Delay(300);Check(race.Status=="连接被拒绝"&&race.Detail==refusal,"watchdog overwrote refusal");race.Handle("connectionState=Connected");
    File.Delete(trace+".probing");File.WriteAllText(trace+".slowping","");int beforeSave=Launches().Length;
    race.NetworkSignal();await Until(()=>File.Exists(trace+".probing"));race.InvertHorizontal=!race.InvertHorizontal;race.SaveAndApply();
    await Until(()=>Launches().Length==beforeSave+1&&race.Connected);File.Delete(trace+".slowping");race.SaveAndApply();await Task.Delay(200);
    Check(Launches().Length==beforeSave+1,"save during probe lost or duplicated");
    race.AutoConnect=false;File.WriteAllText(trace+".slowstop","");File.Delete(trace+".stopping");int beforePause=Launches().Length;
    race.InvertVertical=!race.InvertVertical;race.SaveAndApply();await Until(()=>File.Exists(trace+".stopping"));desktopReady=false;race.PauseSignal();
    await Until(()=>!race.Running);await Task.Delay(200);Check(Launches().Length==beforePause,"reload launched while paused");
    desktopReady=true;race.ResumeSignal();await Until(()=>race.Connected&&Launches().Length==beforePause+1);
    race.AutoConnect=true;File.Delete(trace+".stopping");int beforeStorm=Launches().Length;
    race.ObserveDiscovered(new PairedDevice{Fingerprint=pin,Name="RenamedPeer",Address="127.0.0.4",Role="server",Platform="Windows"});
    await Until(()=>File.Exists(trace+".stopping"));for(int i=0;i<100;i++)race.NetworkSignal();
    race.ObserveDiscovered(new PairedDevice{Fingerprint=pin,Name="RenamedPeer",Address="127.0.0.5",Role="server",Platform="Windows"});
    await Until(()=>race.Connected&&Launches().Length==beforeStorm+1);await Task.Delay(500);Check(Launches().Length==beforeStorm+1,"network storm caused duplicate reload");
    Check(File.ReadAllText(Path.Combine(profile,"connections",pin,"LinkDesk.conf")).Contains("remoteHost=127.0.0.5"),"reload used stale address");
    race.Stop();race.Handle("connectionState=Connected");race.Handle("connectedClients=late");race.ObserveConnectionOutput("connected to secure socket");
    Check(!race.Connected&&race.Status!="两台电脑已连接","late message undid stop");await Until(()=>!race.Running);File.Delete(trace+".slowstop");
    var trust=Path.Combine(profile,"connections",pin,"tls","trusted-servers");var trustBefore=File.ReadAllText(trust);
    try{race.UpdateSelectedAddress(pin,"127.0.0.6\ninjected=1");throw new Exception("unsafe address accepted");}catch(ArgumentException){}
    try{race.UpdateSelectedAddress(new string('b',64),"127.0.0.6");throw new Exception("unselected identity edited");}catch(InvalidOperationException){}
    race.UpdateSelectedAddress(pin,"127.0.0.6");var saved=new PeerStore(profile);
    Check(saved.Selected?.Address=="127.0.0.6"&&saved.Selected?.Fingerprint==pin&&saved.Selected.Paired&&File.ReadAllText(trust)==trustBefore,"address edit changed identity or trust");
    race.Start();await Until(()=>race.Connected);race.Handle("peerFingerprint="+new string('b',64));await Until(()=>!race.Running);race.Handle("connectionState=Connected");
    Check(race.Status=="设备身份不一致"&&!race.Connected,"exit erased identity rejection");
   }
   int finalLaunchCount=Launches().Length;
   // Recreate a remembered session without ever waiting for the startup delay.
   var prefs=JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(profile,"preferences.json")))!;prefs.AutoStartOnLaunch=true;prefs.LastSessionRequested=true;
   model.Dispose();File.WriteAllText(Path.Combine(profile,"preferences.json"),JsonSerializer.Serialize(prefs));
   using var queued=new LinkModel(profile,Path.GetFullPath(core),false,()=>new(true,"fixture-display"),TimeSpan.FromMilliseconds(30));queued.BeginAutomaticStart();queued.Stop();await queued.AutomaticStartTask;
   Check(Launches().Length==finalLaunchCount,"stop did not cancel opted-in queued startup");
  }catch{
   var log=Path.Combine(profile,"linkdesk-session.log");if(File.Exists(log))foreach(var line in File.ReadLines(log).TakeLast(80))Console.Error.WriteLine(line);
   throw;
  }finally{
   // Cleanup is confined to fake processes launched by this test, never user cores.
   foreach(int id in Launches())try{using var p=Process.GetProcessById(id);if(!p.HasExited)p.Kill();}catch{}
  }
  Directory.Delete(root,true);
 }
}
