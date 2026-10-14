using System;
using LinkDesk;
class RecoveryIntentTests {
 static void Check(bool value,string reason){if(!value)throw new Exception(reason);}
 static void Main(){
  var state=new RecoveryIntent();long request=state.Signal();
  Check(state.Decide(request,true,true,true,false,false,false)==RecoveryAction.None,"legacy auto-recovery resurrected an unauthorized session");
  state.StartSession();request=state.Signal();state.StopSession();
  Check(state.Decide(request,true,true,true,false,false,false)==RecoveryAction.None,"queued callback restarted manual stop");
  state.StartSession();long older=state.Signal();for(int i=0;i<100;i++)request=state.Signal();
  Check(!state.Current(older,true),"network burst did not invalidate old work");
  Check(state.Decide(request,true,true,true,true,true,false)==RecoveryAction.Keep,"healthy wake/network event restarted a core");
  Check(state.Decide(request,true,true,true,true,true,true)==RecoveryAction.Reload,"genuine selected endpoint change did not reload");
  Check(state.Decide(request,true,true,true,true,false,false)==RecoveryAction.Hold,"unresponsive core caused an automatic kill/relaunch");
  Check(state.Decide(request,false,true,true,false,false,false)==RecoveryAction.None,"disabled recovery restarted a core");
  Check(state.Decide(request,true,false,true,false,false,false)==RecoveryAction.Wait,"locked/unready desktop started a core");
  Check(state.Decide(request,true,true,false,false,false,false)==RecoveryAction.Wait,"no network started a core");
  state.Pause(true);Check(!state.Current(request,true),"suspend failed to cancel queued work");
  state.Pause(false);request=state.Signal();Check(state.Decide(request,true,true,true,true,true,false)==RecoveryAction.Keep,"resume restarted a healthy core");
  state.Block();request=state.Signal();Check(!state.Current(request,true),"blocked process resumed automatically");
  var stable=new DesktopStability();var now=DateTimeOffset.UtcNow;var a=new DesktopSnapshot(true,"physical-a");
  Check(!stable.Observe(a,now,TimeSpan.FromSeconds(5)),"one frame declared desktop stable");
  Check(!stable.Observe(new(false,""),now.AddSeconds(6),TimeSpan.FromSeconds(5)),"locked/absent display retained readiness");
  Check(!stable.Observe(a,now.AddSeconds(7),TimeSpan.FromSeconds(5)),"unlock retained stale stability");
  Check(stable.Observe(a,now.AddSeconds(12),TimeSpan.FromSeconds(5)),"stable physical desktop never became ready");
  Check(!stable.Observe(new(true,"physical-b"),now.AddSeconds(13),TimeSpan.FromSeconds(5)),"topology change retained stability");
  Check(WindowsDesktopState.DisplayPathSize==72,"DISPLAYCONFIG_PATH_INFO ABI size mismatch");
  Console.WriteLine("Recovery intent checks passed: no unauthorized starts, cancellation, burst coalescing revision, healthy process retention, blocked core, desktop topology stability.");
 }
}
