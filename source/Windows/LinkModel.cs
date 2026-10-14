using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using Microsoft.Win32;

namespace LinkDesk;
public sealed class Preferences {
 public string LocalName {get;set;} = "";
 public string PeerName {get;set;} = "";
 public string Host {get;set;} = "";
 public bool Server {get;set;}
 public string Layout {get;set;} = "left";
 public bool KeepBackground {get;set;} = true;
 public bool AutoConnect {get;set;}
 public string MapSuper {get;set;}="super";
 public string MapControl {get;set;}="ctrl";
 public string MapOption {get;set;}="alt";
 public string MapShift {get;set;}="shift";
 public bool InvertVertical {get;set;}
 public bool InvertHorizontal {get;set;}
 public double VerticalSpeed {get;set;}=1;
 public double HorizontalSpeed {get;set;}=1;
 public bool AutoDiscover {get;set;}=true;
}
public sealed class LinkModel : INotifyPropertyChanged, IDisposable {
 public event PropertyChangedEventHandler? PropertyChanged;
 private void Changed([CallerMemberName] string? key = null) => PropertyChanged?.Invoke(this,new PropertyChangedEventArgs(key));
 private readonly string folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LinkDesk");
 private readonly string tlsFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LinkDesk","tls");
 private readonly string engine = Path.Combine(AppContext.BaseDirectory,"core","deskflow-core.exe");
 private Preferences preferences;
 private Process? child;
 private NamedPipeClientStream? pipe;
 private CancellationTokenSource? session;
 private bool desired;
 private bool disposed;
 private bool restarting;
 private long recoveryRequest;
 private DiscoveryClient? discovery;
 private DiscoveryResponder? announcement;
 private PeerStore? peers;
 private string activeProfile="";
 private long discoveryGeneration;
 public ObservableCollection<PairedDevice> Devices {get;private set;}=new();
 public PairedDevice? SelectedDevice=>peers?.Selected;
 public string CurrentPeerLabel=>SelectedDevice?.Label??"尚未选择设备";
 public string CurrentPeerSummary=>SelectedDevice is null?"请先到配对设备中选择电脑。":$"{SelectedDevice.PlatformLabel} · {SelectedDevice.RoleLabel} · 指纹 {SelectedDevice.ShortID}";
 public string ManualName {get;set;}="";
 public string ManualHost {get;set;}="";
 public string ManualFingerprint {get;set;}="";
 public string ManualPlatform {get;set;}="unknown";
 private DateTime lastDiscoverySeen=DateTime.MinValue;
 private int failures;
 private long generation;
 private readonly HashSet<string> seen = new();
 public ObservableCollection<string> Logs {get;} = new();
 public string LocalName {get=>preferences.LocalName;set{preferences.LocalName=value;Changed();}}
 public string PeerName {get=>preferences.PeerName;set{preferences.PeerName=value;Changed();}}
 public string Host {get=>preferences.Host;set{preferences.Host=value;Changed();}}
 public bool Server {get=>preferences.Server;set{preferences.Server=value;Changed();Changed(nameof(Role));Changed(nameof(IsReceiver));Changed(nameof(CanMap));Changed(nameof(CanScroll));Changed(nameof(MappingHint));Changed(nameof(ScrollingHint));Changed(nameof(CanManualHost));}}
 public bool IsReceiver {get=>!Server;set{if(value)Server=false;}}
 public string Role {get=>Server?"共享本机键鼠":"接收另一台电脑的键鼠";}
 public string Layout {get=>preferences.Layout;set{preferences.Layout=value;Changed();}}
 public bool KeepBackground {get=>preferences.KeepBackground;set{preferences.KeepBackground=value;Save();Changed();}}
 public bool AutoConnect {get=>preferences.AutoConnect;set{preferences.AutoConnect=value;Save();Changed();}}
 public bool AutoDiscover {get=>preferences.AutoDiscover;set{preferences.AutoDiscover=value;Save();Changed();Changed(nameof(CanManualHost));ConfigureDiscovery();}}
 public bool CanManualHost=>CanEdit&&!Server;
 public string LocalFingerprint {get;private set;}="正在准备本机身份…";
 private string discoveryStatus="正在查找局域网设备";
 public string DiscoveryStatus {get=>discoveryStatus;private set{discoveryStatus=value;Changed();}}
 public string MapSuper {get=>preferences.MapSuper;set{preferences.MapSuper=value;Changed();}}
 public string MapControl {get=>preferences.MapControl;set{preferences.MapControl=value;Changed();}}
 public string MapOption {get=>preferences.MapOption;set{preferences.MapOption=value;Changed();}}
 public string MapShift {get=>preferences.MapShift;set{preferences.MapShift=value;Changed();}}
 public bool InvertVertical {get=>preferences.InvertVertical;set{preferences.InvertVertical=value;Changed();}}
 public bool InvertHorizontal {get=>preferences.InvertHorizontal;set{preferences.InvertHorizontal=value;Changed();}}
 public double VerticalSpeed {get=>preferences.VerticalSpeed;set{preferences.VerticalSpeed=value;Changed();}}
 public double HorizontalSpeed {get=>preferences.HorizontalSpeed;set{preferences.HorizontalSpeed=value;Changed();}}
 public bool CanMap=>Server&&!Running;
 public bool CanScroll=>!Server&&!Running;
 public string MappingHint=>Server?"只改变另一台电脑收到的按键，本机键盘保持原样。":"按键映射由共享端发送。请在另一台电脑的“键盘与鼠标”中设置。";
 public string ScrollingHint=>Server?"接收端滚动设置请在另一台电脑调整。":"仅调整来自另一台电脑的远程滚动，不影响本机鼠标。";
 public void MappingPreset(bool macHabit){MapSuper=macHabit?"ctrl":"super";MapControl=macHabit?"super":"ctrl";MapOption="alt";MapShift="shift";}
 public void ResetScrolling(){InvertVertical=false;InvertHorizontal=false;VerticalSpeed=1;HorizontalSpeed=1;}
 private bool running;
 public bool Running {get=>running;private set{running=value;Changed();Changed(nameof(StartLabel));Changed(nameof(CanEdit));Changed(nameof(CanMap));Changed(nameof(CanScroll));Changed(nameof(CanManualHost));}}
 public bool CanEdit => !Running;
 public string StartLabel => Running?"停止共享":"启动共享";
 private bool connected;
 public bool Connected {get=>connected;private set{connected=value;Changed();}}
 private string status="准备连接",detail="选择已配对设备后启动连接。";
 public string Status {get=>status;private set{status=value;Changed();}}
 public string Detail {get=>detail;private set{detail=value;Changed();}}
 public string Address => Server?string.Join(" / ",NetworkInterface.GetAllNetworkInterfaces().Where(n=>n.OperationalStatus==OperationalStatus.Up).SelectMany(n=>n.GetIPProperties().UnicastAddresses).Where(a=>a.Address.AddressFamily==AddressFamily.InterNetwork&&!a.Address.ToString().StartsWith("127.")).Select(a=>a.Address.ToString())):Host;
 public void PropertyChangedForAddress()=>Changed(nameof(Address));
 public bool LoginEnabled {
  get { using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); return key?.GetValue("LinkDesk") is string; }
  set {
   try {
    using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
    if(value) { key.SetValue("LinkDesk","\""+Environment.ProcessPath+"\" --background"); AutoConnect=true; }
    else key.DeleteValue("LinkDesk",false);
   } catch(Exception e) { MessageBox.Show("设置未生效："+e.Message,"LinkDesk"); }
   Changed();
  }
 }
 public LinkModel() {
  try { preferences=JsonSerializer.Deserialize<Preferences>(File.ReadAllText(Path.Combine(folder,"preferences.json")))??new(); } catch { preferences=new(); }
  try{
   PrepareIdentity();
   if(!Name(LocalName)){var machine=Regex.Replace(Environment.MachineName,"[^A-Za-z0-9_.-]","-").Trim('-');if(string.IsNullOrEmpty(machine))machine="Windows";LocalName=machine[..Math.Min(100,machine.Length)]+"-"+PeerStore.Pin(LocalFingerprint)![..6];}
   peers=new PeerStore(folder);peers.Migrate(PeerName,Host,Server,CurrentInput());ApplySelected(true);RefreshDevices();Save();
  }catch(Exception e){Log("身份或设备列表准备失败："+e.Message);Detail=e.Message;}
  // Keep an existing enabled login item pointing at the executable after an update/move.
  try{using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run",true);if(key?.GetValue("LinkDesk") is string)key.SetValue("LinkDesk","\""+Environment.ProcessPath+"\" --background");}catch(Exception e){Log("自启动路径更新失败："+e.Message);}
  ConfigureDiscovery();
  NetworkChange.NetworkAddressChanged+=NetworkChanged;
  SystemEvents.PowerModeChanged+=PowerChanged;
  if(AutoConnect) _=Task.Delay(1000).ContinueWith(_=>Application.Current.Dispatcher.Invoke(Start));
 }
 private void PrepareIdentity(){LocalFingerprint=LinkIdentity.Prepare(folder,Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"Deskflow","tls"));Changed(nameof(LocalFingerprint));}
 private PeerInput CurrentInput()=>new(){Command=MapSuper,Control=MapControl,Option=MapOption,Shift=MapShift,InvertVertical=InvertVertical,InvertHorizontal=InvertHorizontal,VerticalSpeed=VerticalSpeed,HorizontalSpeed=HorizontalSpeed};
 private void ApplySelected(bool restoreInput) {
  var peer=SelectedDevice;if(peer is null)return;PeerName=peer.Name;Host=peer.Address;
  if(restoreInput){var input=peer.Input??new PeerInput{Command=peer.Platform=="macOS"?"ctrl":"super",Control=peer.Platform=="macOS"?"super":"ctrl"};MapSuper=input.Command;MapControl=input.Control;MapOption=input.Option;MapShift=input.Shift;InvertVertical=input.InvertVertical;InvertHorizontal=input.InvertHorizontal;VerticalSpeed=input.VerticalSpeed;HorizontalSpeed=input.HorizontalSpeed;}
  Changed(nameof(Address));Changed(nameof(CurrentPeerLabel));Changed(nameof(CurrentPeerSummary));
 }
 private void RefreshDevices(){Devices=new ObservableCollection<PairedDevice>(peers?.Devices??Array.Empty<PairedDevice>());Changed(nameof(Devices));Changed(nameof(SelectedDevice));Changed(nameof(CurrentPeerLabel));Changed(nameof(CurrentPeerSummary));}
 public void SelectDevice(string id) {
  if(Running){MessageBox.Show("请先停止共享，再切换设备。","LinkDesk");return;}
  var peer=peers?.Devices.FirstOrDefault(d=>d.Id==id);if(peer is null)return;
  if(peer.Role==(Server?"server":"client")){MessageBox.Show("两端用途相同。请把一端设为共享键鼠、另一端设为接收键鼠。","LinkDesk");return;}
  if(!peer.Paired&&MessageBox.Show($"核对 {peer.Label} 的本机指纹：\n\n{peer.FormattedFingerprint}\n\n只有与对方连接页显示的完整指纹一致时才允许配对。", "确认设备身份",MessageBoxButton.YesNo,MessageBoxImage.Question)!=MessageBoxResult.Yes)return;
  try{Stop();peers!.SetInput(CurrentInput());if(peer.Paired)peers.Select(id);else peers.Pair(id);ApplySelected(true);Save();RefreshDevices();Status="已选择 "+CurrentPeerLabel;Detail="点击启动共享；另一端也需选择本机并确认配对。";}catch(Exception e){MessageBox.Show(e.Message,"LinkDesk");}
 }
 public void AddManualDevice() {
  var pin=PeerStore.Pin(ManualFingerprint);
  if(pin==PeerStore.Pin(LocalFingerprint)||!Name(ManualName)||!Regex.IsMatch(ManualHost,@"^[A-Za-z0-9_.:\[\]-]{1,255}$")||pin is null){MessageBox.Show("请输入对方的本机名称、地址和完整 SHA-256 本机指纹。","LinkDesk");return;}
  try{peers?.Observe(new PairedDevice{Fingerprint=pin,Name=ManualName,Address=ManualHost,Platform=ManualPlatform,Role=Server?"client":"server"});RefreshDevices();SelectDevice(pin);}catch(Exception e){MessageBox.Show(e.Message,"LinkDesk");}
 }
 public void RenameDevice(string id,string alias){try{peers?.Rename(id,alias);RefreshDevices();}catch(Exception e){MessageBox.Show(e.Message,"LinkDesk");}}
 public void ForgetDevice(string id){if(Running){MessageBox.Show("请先停止共享，再忘记设备。","LinkDesk");return;}try{if(SelectedDevice?.Id==id)Stop();peers?.Forget(id);RefreshDevices();Status="配对已移除";Detail="再次连接需要重新核对指纹。";}catch(Exception e){MessageBox.Show(e.Message,"LinkDesk");}}
 public void RefreshDiscovery()=>discovery?.Refresh();
 public void ConfigureDiscovery() {
  var revision=++discoveryGeneration;discovery?.Dispose();discovery=null;announcement?.Dispose();announcement=null;
  if(disposed||!AutoDiscover){DiscoveryStatus="发现已关闭，可手动添加设备。";return;}
  var pin=PeerStore.Pin(LocalFingerprint);if(pin is null||!Name(LocalName)){DiscoveryStatus="请先准备本机身份和名称。";return;}
  try{announcement=new DiscoveryResponder(LocalName,Server?"server":"client",Path.Combine(tlsFolder,"deskflow.pem"));}catch(Exception e){Log("设备公告："+e.Message);}
  discovery=new DiscoveryClient(pin,()=>Host,
   incoming=>Application.Current.Dispatcher.BeginInvoke(()=>{
    if(disposed||revision!=discoveryGeneration||peers is null)return;
    try{
     var oldName=SelectedDevice?.Name;var oldAddress=SelectedDevice?.Address;
     bool selected=peers.Observe(incoming);RefreshDevices();
     if(selected){bool returned=(DateTime.UtcNow-lastDiscoverySeen).TotalSeconds>12;lastDiscoverySeen=DateTime.UtcNow;ApplySelected(false);Save();
      if(SelectedDevice!.Role!=(Server?"client":"server")){if(Running)Stop();Detail="对方用途已改变，请设置两端为共享与接收。";return;}
      if(oldName!=incoming.Name||oldAddress!=incoming.Address||returned)RequestRecovery("已核对所选设备的身份",oldName!=incoming.Name||(!Server&&oldAddress!=incoming.Address));
     }
    }catch(Exception e){Log("设备列表："+e.Message);}
   }),message=>Application.Current.Dispatcher.BeginInvoke(()=>{if(!disposed&&revision==discoveryGeneration){DiscoveryStatus=message;RefreshDevices();}}));
 }
 private void NetworkChanged(object? sender,EventArgs e)=>Application.Current.Dispatcher.BeginInvoke(()=>{if(!disposed){Changed(nameof(Address));discovery?.Refresh();RequestRecovery("网络恢复或地址变化");}});
 private void PowerChanged(object sender,PowerModeChangedEventArgs e){if(e.Mode==PowerModes.Resume)Application.Current.Dispatcher.BeginInvoke(()=>{if(!disposed){discovery?.Refresh();RequestRecovery("电脑唤醒",true);}});}
 private async void RequestRecovery(string reason,bool force=false) {
  if(disposed||!AutoConnect)return;
  var request=++recoveryRequest;
  await Task.Delay(3000);
  if(disposed||!AutoConnect||request!=recoveryRequest||restarting||(!force&&Connected))return;
  if(!NetworkInterface.GetAllNetworkInterfaces().Any(n=>n.OperationalStatus==OperationalStatus.Up&&n.NetworkInterfaceType!=NetworkInterfaceType.Loopback))return;
  Log(reason+"，正在恢复共享。");
  if(!Running){Start();return;}
  restarting=true;desired=true;var id=++generation;var owned=child;
  Status="正在恢复共享";Connected=false;SendStop();session?.Cancel();pipe?.Dispose();pipe=null;
  try {
   if(owned is not null&&!owned.HasExited){
    var exit=owned.WaitForExitAsync();
    if(await Task.WhenAny(exit,Task.Delay(2000))!=exit&&!owned.HasExited)owned.Kill();
    if(await Task.WhenAny(exit,Task.Delay(2000))!=exit)throw new Exception("旧共享进程尚未退出");
   }
   if(owned is not null)owned.Dispose();
   child=null;Running=false;restarting=false;
   if(!disposed&&AutoConnect&&generation==id){WriteConfiguration();Launch();}
  }catch(Exception e){restarting=false;try{Running=child is not null&&!child.HasExited;}catch{Running=false;}Status="恢复暂未完成";Detail=e.Message;}
 }
 public void Save() { try {peers?.SetInput(CurrentInput());Directory.CreateDirectory(folder);File.WriteAllText(Path.Combine(folder,"preferences.json"),JsonSerializer.Serialize(preferences,new JsonSerializerOptions{WriteIndented=true}));}catch(Exception e){MessageBox.Show("保存失败："+e.Message,"LinkDesk");} }
 private void Log(string line) {Logs.Add(line);while(Logs.Count>300)Logs.RemoveAt(0);}
 private static bool Name(string s)=>Regex.IsMatch(s,@"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$");
 public void Start() {
  if(disposed)return;
  if(Running)return;
  if(!File.Exists(engine)){MessageBox.Show("安装包中的连接核心不完整。请重新解压整个 LinkDesk 安装包，不要只复制 LinkDesk.exe。","LinkDesk");return;}
  if(Process.GetProcessesByName("deskflow").Any()||Process.GetProcessesByName("deskflow-core").Any()){MessageBox.Show("请先从系统托盘退出原版 Deskflow，然后在 LinkDesk 启动连接。","LinkDesk");return;}
  if(SelectedDevice is null){MessageBox.Show("请先在配对设备中选择并核对一台电脑。","LinkDesk");return;}
  ApplySelected(false);
  if(!Name(LocalName)||!Name(PeerName)||LocalName==PeerName){MessageBox.Show("电脑名称仅支持字母、数字、点、短横线和下划线，两台不能重名。","LinkDesk");return;}
  if(!Server&&!Regex.IsMatch(Host,@"^[A-Za-z0-9_.:\[\]-]{1,255}$")){MessageBox.Show("请输入有效的共享端地址。","LinkDesk");return;}
  if(!File.Exists(Path.Combine(Path.GetDirectoryName(engine)!,"settings","Deskflow.conf"))){MessageBox.Show("连接核心的便携配置缺失，请重新解压完整安装包。","LinkDesk");return;}
  try {
   PrepareIdentity();ConfigureDiscovery();WriteConfiguration();
   AutoConnect=true;Save();desired=true;failures=0;Launch();
  }catch(Exception e){MessageBox.Show("无法启动："+e.Message,"LinkDesk");}
 }
 private void WriteConfiguration() {
   activeProfile=peers?.Session(Server)??throw new InvalidOperationException("设备列表未就绪");
   var config=Path.Combine(activeProfile,"linkdesk-server.conf");
   var mapping=InputConfiguration.Mapping(MapSuper,MapControl,MapOption,MapShift);
   var scrolling=InputConfiguration.Scrolling(InvertVertical,InvertHorizontal,VerticalSpeed,HorizontalSpeed);
   var reverse=new Dictionary<string,string>{{"right","left"},{"left","right"},{"up","down"},{"down","up"}};
   var dir=reverse.ContainsKey(Layout)?Layout:"left";
   File.WriteAllText(config,$"section: links\n\t{LocalName}:\n\t\t{dir} = {PeerName}\n\t{PeerName}:\n\t\t{reverse[dir]} = {LocalName}\nend\n\nsection: options\nend\n");
   File.WriteAllText(Path.Combine(activeProfile,"LinkDesk.conf"),$"[core]\ncomputerName={LocalName}\ncoreMode={(Server?2:1)}\nprocessMode=0\nport=24800\n[computer_{LocalName}]\nname={LocalName}\n[computer_{PeerName}]\nname={PeerName}\n{(Server?mapping:"")}[client]\nremoteHost={Host}\nlanguageSync=false\ndynamicConnectionInterval=true\n{scrolling}[server]\nexternalConfig=true\nexternalConfigFile={config.Replace('\\','/')}\nprotocol=barrier\nenableClipboard=true\nclipboardSize=3\n[security]\ntlsEnabled=true\ncheckPeerFingerprints=true\n[log]\nlevel=Info\n");
 }
 private void Launch() {
  if(disposed||!desired)return;
  if(Process.GetProcessesByName("deskflow").Any()||Process.GetProcessesByName("deskflow-core").Any()){desired=false;Running=false;Status="另一个连接正在运行";Detail="请先退出原版 Deskflow，再启动 LinkDesk。";return;}
  long id=++generation;seen.Clear();Connected=false;session=new();
  var p=new Process{StartInfo=new ProcessStartInfo(engine){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true},EnableRaisingEvents=true};
  p.StartInfo.Environment["XDG_STATE_HOME"]=activeProfile;
  p.StartInfo.ArgumentList.Add(Server?"server":"client");p.StartInfo.ArgumentList.Add("--new-instance");p.StartInfo.ArgumentList.Add("--settings");p.StartInfo.ArgumentList.Add(Path.Combine(activeProfile,"LinkDesk.conf"));
  void Line(object sender,DataReceivedEventArgs e){if(e.Data is null)return;Application.Current.Dispatcher.BeginInvoke(()=>{if(id!=generation)return;Log(e.Data);if(e.Data.Contains("FATAL")||e.Data.Contains("ERROR"))Detail="启动遇到问题，请查看连接日志。";});}
  p.OutputDataReceived+=Line;p.ErrorDataReceived+=Line;
  p.Exited+=(_,_)=>Application.Current.Dispatcher.BeginInvoke(async()=>{
   if(id!=generation)return;
   int exit=p.ExitCode;Running=false;Connected=false;pipe?.Dispose();pipe=null;session?.Cancel();
   if(desired&&exit!=0&&++failures<=3){Status="启动失败，稍后重试";Detail="检查权限和另一台电脑的设置。";await Task.Delay(failures*5000);if(desired&&id==generation)Launch();}
   else {desired=false;Status=exit==0?"已停止":"启动失败";Detail=exit==0?"点击启动，恢复键鼠共享。":"已停止重试，请查看日志后重新启动。";}
  });
  try {p.Start();child=p;Running=true;Status=Server?"等待所选设备":"正在连接所选设备";Detail="保持两台电脑联网，连接会自动恢复。";Changed(nameof(Address));p.BeginOutputReadLine();p.BeginErrorReadLine();_=ReadChannel(id,session.Token);}
  catch(Exception e){desired=false;MessageBox.Show(e.Message,"LinkDesk");}
 }
 private async Task ReadChannel(long id,CancellationToken token) {
  try {
   await Task.Delay(1200,token);
   var client=new NamedPipeClientStream(".","deskflow-core",PipeDirection.InOut,PipeOptions.Asynchronous);
   try{await client.ConnectAsync(7000,token);}catch{client.Dispose();throw;}
   if(id!=generation||token.IsCancellationRequested){client.Dispose();return;}pipe=client;
   using var reader=new StreamReader(client,Encoding.UTF8,false,4096,true);
   async Task Send(string s){var b=Encoding.UTF8.GetBytes(s+"\n");await client.WriteAsync(b,token);await client.FlushAsync(token);}
   await Send("hello=LinkDesk");
   while(!token.IsCancellationRequested){var line=await reader.ReadLineAsync(token);if(line is null)break;if(line.StartsWith("versionMismatch=")){await Send("hello="+line[16..]);continue;}await Application.Current.Dispatcher.InvokeAsync(()=>{if(id==generation)Handle(line);});}
  }catch(OperationCanceledException){}catch(Exception e){if(!token.IsCancellationRequested) _=Application.Current.Dispatcher.BeginInvoke(()=>Log("状态通道："+e.Message));}
 }
 private void Handle(string message) {
  var parts=message.Split('=',2);var args=parts.Length>1?parts[1]:"";
  switch(parts[0]){
   case "connectionState":Connected=args=="Connected";Status=Connected?"两台电脑已连接":Server?"等待所选设备":"正在重连所选设备";Detail=Connected?"键盘和鼠标可以在两台电脑间使用。":"网络恢复后会自动重连。";break;
   case "connectedClients":Connected=args.Length>0;Status=Connected?"两台电脑已连接":"等待另一台电脑";Detail=Connected?"已连接："+args:"等待安全连接。";break;
   case "connectionRefused":Detail="对方拒绝连接："+args;break;
   case "peerFingerprint":
    var observed=PeerStore.Pin(args);if(observed is null||!seen.Add(observed))break;
    if(observed!=SelectedDevice?.Fingerprint){Stop();Status="设备身份不一致";Detail="对方指纹与所选设备不同，连接已停止。请先在设备列表重新核对身份。";Log("拒绝身份不一致的连接；没有修改配对。");}break;
  }
 }
 public void Toggle()=> (Running? (Action)Stop:Start)();
 public void Stop(){desired=false;AutoConnect=false;recoveryRequest++;Connected=false;var p=child;if(p is null||p.HasExited){Running=false;Status="已停止";return;}SendStop();_=Task.Delay(1000).ContinueWith(_=>{try{if(!p.HasExited)p.Kill();}catch{}Application.Current.Dispatcher.BeginInvoke(()=>{if(child==p&&!AutoConnect){Running=false;Status="已停止";}});});Status="正在停止";}
 private void SendStop(){try{if(pipe?.IsConnected==true){var bytes=Encoding.UTF8.GetBytes("stop\n");pipe.Write(bytes);pipe.Flush();}}catch{}}
 public void Dispose(){if(disposed)return;disposed=true;desired=false;recoveryRequest++;discoveryGeneration++;discovery?.Dispose();announcement?.Dispose();NetworkChange.NetworkAddressChanged-=NetworkChanged;SystemEvents.PowerModeChanged-=PowerChanged;SendStop();try{if(child is not null&&!child.HasExited&&!child.WaitForExit(2000))child.Kill();}catch{}session?.Cancel();pipe?.Dispose();child?.Dispose();}
}
