using System;
using System.Globalization;
using System.Linq;

namespace LinkDesk;
public static class InputConfiguration {
 public static readonly string[] Modifiers={"ctrl","super","alt","shift","meta","altgr","none"};
 public static string Mapping(string command,string control,string option,string shift) {
  if(!new[]{command,control,option,shift}.All(Modifiers.Contains))throw new ArgumentException("请使用列表中的按键映射。");
  return $"modifierSuper={command}\nmodifierMeta={command}\nmodifierCtrl={control}\nmodifierAlt={option}\nmodifierShift={shift}\n";
 }
 public static string Scrolling(bool vertical,bool horizontal,double y,double x) {
  if(!double.IsFinite(y)||!double.IsFinite(x)||y<0.1||y>10||x<0.1||x>10)throw new ArgumentException("滚动速度须在 0.1–10 倍之间。");
  return $"invertYScroll={vertical.ToString().ToLowerInvariant()}\ninvertXScroll={horizontal.ToString().ToLowerInvariant()}\nyScrollScale={y.ToString(CultureInfo.InvariantCulture)}\nxScrollScale={x.ToString(CultureInfo.InvariantCulture)}\n";
 }
 public static string SwitchDelay(int milliseconds) {
  if(milliseconds<0||milliseconds>5000)throw new ArgumentException("切换停留时间须在 0–5000 毫秒之间。");
  return milliseconds<=0?"":"enableSwitchDelay=true\nswitchDelay="+milliseconds.ToString(CultureInfo.InvariantCulture)+"\n";
 }
}
public static class RefusalMessages {
 public static string Describe(string args)=>args switch{
  "IncompatibleVersion"=>"对方拒绝连接：两端核心版本不兼容。请把两台电脑都更新到同一版 LinkDesk。",
  "AlreadyConnected"=>"对方拒绝连接：已有一台同名电脑在连接中。请确认没有重名的设备，也没有重复启动共享。",
  "UnknownClient"=>"对方拒绝连接：对方没有本机的配对记录。请在对方的“配对设备”中选择并核对本机，并确认两端电脑名称一致。",
  "ProtocolError"=>"对方拒绝连接：握手协议出错。请两端停止共享后重新启动；仍失败请查看连接日志。",
  _=>$"对方拒绝连接（{args}），请核对电脑名称与配对。"
 };
}
