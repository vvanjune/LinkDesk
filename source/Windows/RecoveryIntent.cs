using System;
namespace LinkDesk;

public enum RecoveryAction { None, Wait, Keep, Start, Reload, Hold }

// A persisted preference is not authorization to resurrect a stopped session.
// Every delayed callback must carry the current revision and session intent.
public sealed class RecoveryIntent {
 public bool Requested {get;private set;}
 public bool Paused {get;private set;}
 public bool Blocked {get;private set;}
 public long Revision {get;private set;}
 public void StartSession(){Requested=true;Blocked=false;Revision++;}
 public void StopSession(){Requested=false;Revision++;}
 public void Pause(bool value){Paused=value;Revision++;}
 public void Block(){Blocked=true;Revision++;}
 public long Signal()=>++Revision;
 public bool Current(long revision,bool automatic)=>revision==Revision&&Requested&&automatic&&!Paused&&!Blocked;
 public RecoveryAction Decide(long revision,bool automatic,bool desktopReady,bool networkReady,bool running,bool responsive,bool configurationChanged) {
  if(!Current(revision,automatic))return RecoveryAction.None;
  if(!desktopReady||!networkReady)return RecoveryAction.Wait;
  if(!running)return RecoveryAction.Start;
  if(!responsive)return RecoveryAction.Hold;
  return configurationChanged?RecoveryAction.Reload:RecoveryAction.Keep;
 }
}

// Stability is observed, not inferred from a fixed sleep or first rendered frame.
public sealed class DesktopStability {
 private string? previous;
 private DateTimeOffset since;
 public bool Observe(DesktopSnapshot snapshot,DateTimeOffset now,TimeSpan duration) {
  if(!snapshot.Ready){previous=null;return false;}
  if(previous!=snapshot.Signature){previous=snapshot.Signature;since=now;return false;}
  return now-since>=duration;
 }
}
