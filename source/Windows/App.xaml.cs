using System;
using System.Threading;
using System.Windows;
namespace LinkDesk;
public partial class App : Application {
 private Mutex? mutex;
 protected override void OnStartup(StartupEventArgs e) {
  base.OnStartup(e); mutex = new Mutex(true, "Local\\LinkDeskNative", out bool first);
  if (!first) { MessageBox.Show("LinkDesk 已在运行，请从系统托盘打开。", "LinkDesk"); Shutdown(); return; }
  var window = new MainWindow(); MainWindow = window;
  // A tray-only login should not render a window and then immediately hide it.
  if (Array.IndexOf(e.Args, "--background") < 0 || !window.Model.KeepBackground) window.Show();
  window.Model.BeginAutomaticStart();
 }
 protected override void OnExit(ExitEventArgs e) { (MainWindow as MainWindow)?.Model.Dispose(); mutex?.Dispose(); base.OnExit(e); }
}
