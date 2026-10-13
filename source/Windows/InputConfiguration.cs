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
}
