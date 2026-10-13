using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
namespace LinkDesk;

public sealed class PeerInput {
 public string Command {get;set;}="super";
 public string Control {get;set;}="ctrl";
 public string Option {get;set;}="alt";
 public string Shift {get;set;}="shift";
 public bool InvertVertical {get;set;}
 public bool InvertHorizontal {get;set;}
 public double VerticalSpeed {get;set;}=1;
 public double HorizontalSpeed {get;set;}=1;
}
public sealed class PairedDevice {
 public string Fingerprint {get;set;}="";
 public string Name {get;set;}="";
 public string Address {get;set;}="";
 public string Platform {get;set;}="unknown";
 public string Role {get;set;}="server";
 public string Alias {get;set;}="";
 public bool Paired {get;set;}
 public double LastSeen {get;set;}
 public PeerInput? Input {get;set;}
 [JsonIgnore] public string Id=>Fingerprint;
 [JsonIgnore] public string Label=>string.IsNullOrEmpty(Alias)?Name:Alias;
 [JsonIgnore] public string ShortID=>Fingerprint[..Math.Min(12,Fingerprint.Length)].ToUpperInvariant();
 [JsonIgnore] public string FormattedFingerprint=>string.Join(":",Fingerprint.Chunk(2).Select(p=>new string(p).ToUpperInvariant()));
 [JsonIgnore] public bool Online=>DateTimeOffset.UtcNow.ToUnixTimeSeconds()-LastSeen<25;
 [JsonIgnore] public string PlatformLabel=>Platform is "macOS" or "Windows"?Platform:"系统待确认";
 [JsonIgnore] public string RoleLabel=>Role=="server"?"共享键鼠":"接收键鼠";
 [JsonIgnore] public string Summary=>$"{PlatformLabel} · {RoleLabel} · {(Online?"应用在线":"上次地址")} · {Address}";
 [JsonIgnore] public string ActionLabel=>Paired?"选择连接":"核对指纹并配对";
 [JsonIgnore] public string TrustLabel=>$"{(Paired?"已配对":"未配对，请核对指纹")} · {ShortID}";
}
public sealed class DeviceDatabase {
 public int Version {get;set;}=1;
 public string? SelectedID {get;set;}
 public List<PairedDevice> Devices {get;set;}=new();
}
public sealed class PeerStore {
 private readonly string profile;
 private readonly string file;
 private readonly DeviceDatabase database;
 private static readonly JsonSerializerOptions json=new(){PropertyNamingPolicy=JsonNamingPolicy.CamelCase,WriteIndented=true};
 public IEnumerable<PairedDevice> Devices=>database.Devices.OrderByDescending(d=>d.Paired).ThenBy(d=>d.Label).ThenBy(d=>d.Id);
 public PairedDevice? Selected=>database.Devices.FirstOrDefault(d=>d.Id==database.SelectedID&&d.Paired);
 public static string? Pin(string? value) {
  if(value is null)return null;
  var clean=value.Trim().ToLowerInvariant();if(clean.StartsWith("v2:sha256:"))clean=clean[10..];
  clean=clean.Replace(":","");return Regex.IsMatch(clean,"^[0-9a-f]{64}$")?clean:null;
 }
 public PeerStore(string profile) {
  this.profile=profile;file=Path.Combine(profile,"devices.json");
  database=File.Exists(file)?JsonSerializer.Deserialize<DeviceDatabase>(File.ReadAllText(file),json)??throw new InvalidDataException("设备列表为空"):new();
  if(database.Devices is null||database.Version!=1||database.Devices.Select(d=>d.Id).Distinct().Count()!=database.Devices.Count||
   database.Devices.Any(d=>Pin(d.Fingerprint)!=d.Fingerprint||!Name(d.Name)||d.Role is not ("server" or "client")))
   throw new InvalidDataException("设备列表无效，已保留原文件。请恢复设备列表备份。");
  if(database.SelectedID is not null&&!database.Devices.Any(d=>d.Id==database.SelectedID&&d.Paired))database.SelectedID=null;
 }
 private static bool Name(string value)=>Regex.IsMatch(value,"^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$");
 public void Save() {
  Directory.CreateDirectory(profile);
  var persisted=new DeviceDatabase{SelectedID=database.SelectedID,Devices=database.Devices.Where(d=>d.Paired).Select(d=>new PairedDevice {
   Fingerprint=d.Fingerprint,Name=d.Name,Address=d.Address,Platform=d.Platform,Role=d.Role,Alias=d.Alias,Paired=true,Input=d.Input,LastSeen=0
  }).ToList()};
  var temp=file+"."+Guid.NewGuid().ToString("N")+".tmp";
  try{File.WriteAllText(temp,JsonSerializer.Serialize(persisted,json));File.Move(temp,file,true);}finally{if(File.Exists(temp))File.Delete(temp);}
 }
 public void Migrate(string name,string address,bool server,PeerInput input) {
  if(File.Exists(file)){
   bool changed=false;foreach(var device in database.Devices.Where(d=>d.Paired&&d.Input is null&&d.Name.StartsWith("Imported-"))){device.Input=input;changed=true;}
   if(changed)Save();return;
  }
  var marker=Path.Combine(profile,"device-migration.done");
  if(File.Exists(marker)){Save();return;}
  foreach(var entry in new[]{("trusted-servers","server"),("trusted-clients","client")}) {
   var db=Path.Combine(profile,"tls",entry.Item1);
   var pins=(File.Exists(db)?File.ReadAllLines(db):Array.Empty<string>()).Select(Pin).Where(p=>p is not null).Cast<string>().Distinct().Order().ToArray();
   foreach(var pin in pins) {
    bool known=entry.Item2==(server?"client":"server")&&pins.Length==1&&Name(name);
    database.Devices.Add(new PairedDevice{Fingerprint=pin,Name=known?name:"Imported-"+pin[..8],Address=known?address:"",Platform="unknown",Role=entry.Item2,Alias=known?"":"旧配对 "+pin[..8],Paired=true,Input=input});
    if(known)database.SelectedID=pin;
   }
  }
  database.Devices=database.Devices.GroupBy(d=>d.Id).Select(group=>group.FirstOrDefault(d=>d.Role==(server?"client":"server"))??group.First()).ToList();
  Save();File.WriteAllText(marker,"1\n");
 }
 public bool Observe(PairedDevice incoming) {
  if(Pin(incoming.Fingerprint)!=incoming.Fingerprint||!Name(incoming.Name)||!Regex.IsMatch(incoming.Address,@"^[A-Za-z0-9_.:\[\]-]{1,255}$")||incoming.Role is not ("server" or "client"))return false;
  var device=database.Devices.FirstOrDefault(d=>d.Id==incoming.Id);
  if(device is not null) {
   bool changed=device.Name!=incoming.Name||device.Address!=incoming.Address||device.Platform!=incoming.Platform||device.Role!=incoming.Role;
   if(device.Alias=="旧配对 "+device.Id[..8])device.Alias="";
   device.Name=incoming.Name;device.Address=incoming.Address;device.Platform=incoming.Platform;device.Role=incoming.Role;device.LastSeen=incoming.LastSeen;
   if(changed&&device.Paired)Save();
  }else if(database.Devices.Count(d=>!d.Paired)<64) {
   incoming.Paired=false;incoming.Input=null;incoming.Alias="";database.Devices.Add(incoming);
  }
  return database.SelectedID==incoming.Id&&Selected is not null;
 }
 public void Pair(string id){var d=database.Devices.FirstOrDefault(d=>d.Id==id);if(d is null)return;d.Paired=true;database.SelectedID=id;Save();}
 public void Select(string id){if(!database.Devices.Any(d=>d.Id==id&&d.Paired))return;database.SelectedID=id;Save();}
 public void Rename(string id,string alias){var d=database.Devices.FirstOrDefault(d=>d.Id==id&&d.Paired);if(d is null)return;d.Alias=alias.Trim()[..Math.Min(80,alias.Trim().Length)];Save();}
 public void SetInput(PeerInput input){if(Selected is null)return;Selected.Input=input;Save();}
 public void Forget(string id){if(Pin(id)!=id)return;database.Devices.RemoveAll(d=>d.Id==id);if(database.SelectedID==id)database.SelectedID=null;Save();var folder=Path.Combine(profile,"connections",id);if(Directory.Exists(folder))Directory.Delete(folder,true);}
 public string Session(bool server) {
  var selected=Selected;
  if(selected is null||selected.Role!=(server?"client":"server"))throw new InvalidOperationException("请在配对设备中选择另一台电脑，并将两端分别设为共享键鼠和接收键鼠。");
  return PrepareSession(profile,selected.Fingerprint);
 }
 public static string PrepareSession(string profile,string fingerprint) {
  var pin=Pin(fingerprint)??throw new ArgumentException("无效指纹");
  var folder=Path.Combine(profile,"connections",pin);var tls=Path.Combine(folder,"tls");Directory.CreateDirectory(tls);
  File.Copy(Path.Combine(profile,"tls","deskflow.pem"),Path.Combine(tls,"deskflow.pem"),true);
  foreach(var name in new[]{"trusted-clients","trusted-servers"})File.WriteAllText(Path.Combine(tls,name),"v2:sha256:"+pin+"\n");
  return folder;
 }
}
