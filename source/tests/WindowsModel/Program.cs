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
   int finalLaunchCount=Launches().Length;
   // Recreate a remembered session without ever waiting for the startup delay.
   var prefs=JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(profile,"preferences.json")))!;prefs.AutoStartOnLaunch=true;prefs.LastSessionRequested=true;
   model.Dispose();File.WriteAllText(Path.Combine(profile,"preferences.json"),JsonSerializer.Serialize(prefs));
   using var queued=new LinkModel(profile,Path.GetFullPath(core),false,()=>new(true,"fixture-display"),TimeSpan.FromMilliseconds(30));queued.BeginAutomaticStart();queued.Stop();await queued.AutomaticStartTask;
   Check(Launches().Length==finalLaunchCount,"stop did not cancel opted-in queued startup");
  }finally{
   // Cleanup is confined to fake processes launched by this test, never user cores.
   foreach(int id in Launches())try{using var p=Process.GetProcessById(id);if(!p.HasExited)p.Kill();}catch{}
  }
  Directory.Delete(root,true);
 }
}
