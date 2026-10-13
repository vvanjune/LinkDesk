using System;
using System.Globalization;
using LinkDesk;
class InputSettingsTests {
 static void Check(bool condition){if(!condition)throw new Exception("Input settings check failed");}
 static void Main(){
  CultureInfo.CurrentCulture=CultureInfo.GetCultureInfo("de-DE");
  var scroll=InputConfiguration.Scrolling(true,false,1.3,0.7);
  Check(scroll.Contains("invertYScroll=true\ninvertXScroll=false\nyScrollScale=1.3\nxScrollScale=0.7"));
  var mapping=InputConfiguration.Mapping("ctrl","super","alt","shift");
  Check(mapping.Contains("modifierSuper=ctrl\nmodifierMeta=ctrl\nmodifierCtrl=super"));
  try{InputConfiguration.Mapping("ctrl\n[security]","ctrl","alt","shift");throw new Exception("Injection accepted");}catch(ArgumentException){}
  foreach(var speed in new[]{double.NaN,double.PositiveInfinity,0,10.1}){try{InputConfiguration.Scrolling(false,false,speed,1);throw new Exception("Invalid speed accepted");}catch(ArgumentException){}}
  Console.WriteLine("Windows input configuration checks passed: modifier mapping, direction, speed, locale, validation.");
 }
}
