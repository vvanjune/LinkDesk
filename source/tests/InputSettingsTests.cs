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
  Check(InputConfiguration.SwitchDelay(250)=="enableSwitchDelay=true\nswitchDelay=250\n");
  Check(InputConfiguration.SwitchDelay(0)=="");
  Check(InputConfiguration.SwitchDelay(1000)=="enableSwitchDelay=true\nswitchDelay=1000\n");
  foreach(var delay in new[]{-1,5001}){try{InputConfiguration.SwitchDelay(delay);throw new Exception("Invalid delay accepted");}catch(ArgumentException){}}
  Check(RefusalMessages.Describe("UnknownClient").Contains("配对"));
  Check(RefusalMessages.Describe("AlreadyConnected").Contains("同名"));
  Check(RefusalMessages.Describe("IncompatibleVersion").Contains("版本"));
  Check(RefusalMessages.Describe("Mystery").Contains("Mystery"));
  Console.WriteLine("Windows input configuration checks passed: modifier mapping, direction, speed, locale, validation, switch delay, refusal messages.");
 }
}
