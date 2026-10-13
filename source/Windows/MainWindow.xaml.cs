using System;
using System.ComponentModel;
using System.Linq;
using System.Windows;
using Forms=System.Windows.Forms;
namespace LinkDesk;
public partial class MainWindow : Window {
 public LinkModel Model {get;}=new();
 private readonly Forms.NotifyIcon tray;
 private readonly System.Drawing.Icon trayIcon;
 private bool quitting;
 public MainWindow(){InitializeComponent();DataContext=Model;using(var iconStream=Application.GetResourceStream(new Uri("pack://application:,,,/Assets/LinkDesk.ico")).Stream){using var source=new System.Drawing.Icon(iconStream);trayIcon=(System.Drawing.Icon)source.Clone();}tray=new Forms.NotifyIcon{Icon=trayIcon,Text="LinkDesk",Visible=true};var menu=new Forms.ContextMenuStrip();menu.Items.Add("打开 LinkDesk",null,(_,_)=>Dispatcher.Invoke(()=>{Show();Activate();}));menu.Items.Add("退出并停止共享",null,(_,_)=>Dispatcher.Invoke(()=>{quitting=true;Close();}));tray.ContextMenuStrip=menu;tray.DoubleClick+=(_,_)=>Dispatcher.Invoke(()=>{Show();Activate();});Closing+=OnClosing;}
 private void OnClosing(object? sender,CancelEventArgs e){if(!quitting&&Model.KeepBackground){e.Cancel=true;Hide();return;}tray.Visible=false;tray.Dispose();trayIcon.Dispose();Model.Dispose();Application.Current.Shutdown();}
 private void Page(string name){ConnectionPage.Visibility=name=="connection"?Visibility.Visible:Visibility.Collapsed;SettingsPage.Visibility=name=="settings"?Visibility.Visible:Visibility.Collapsed;InputPage.Visibility=name=="input"?Visibility.Visible:Visibility.Collapsed;LogsPage.Visibility=name=="logs"?Visibility.Visible:Visibility.Collapsed;PageTitle.Text=name=="connection"?"让工作自然流动":name=="settings"?"按你的习惯运行":name=="input"?"熟悉的按键，顺手的滚动":"连接日志";PageSubtitle.Text=name=="connection"?"把注意力留给工作，让键鼠跟随你。":name=="settings"?"设置一次，以后轻松连接。":name=="input"?"按键映射与滚动设置，在这里一起调整。":"这里记录真实的连接与错误信息。";}
 private void ShowConnection(object s,RoutedEventArgs e)=>Page("connection");
 private void ShowSettings(object s,RoutedEventArgs e)=>Page("settings");
 private void ShowLogs(object s,RoutedEventArgs e)=>Page("logs");
 private void ShowInput(object s,RoutedEventArgs e)=>Page("input");
 private void MacMapping(object s,RoutedEventArgs e)=>Model.MappingPreset(true);
 private void OriginalMapping(object s,RoutedEventArgs e)=>Model.MappingPreset(false);
 private void ResetScrolling(object s,RoutedEventArgs e)=>Model.ResetScrolling();
 private void SaveInput(object s,RoutedEventArgs e){try{_=InputConfiguration.Mapping(Model.MapSuper,Model.MapControl,Model.MapOption,Model.MapShift);_=InputConfiguration.Scrolling(Model.InvertVertical,Model.InvertHorizontal,Model.VerticalSpeed,Model.HorizontalSpeed);Model.Save();MessageBox.Show("已保存，下次启动共享时生效。","LinkDesk");}catch(Exception error){MessageBox.Show(error.Message,"LinkDesk");}}
 private void ToggleConnection(object s,RoutedEventArgs e)=>Model.Toggle();
 private void SaveSettings(object s,RoutedEventArgs e){Model.Save();Model.ConfigureDiscovery();Model.PropertyChangedForAddress();MessageBox.Show("已保存，下次启动连接时生效。","LinkDesk");}
 private void CopyLogs(object s,RoutedEventArgs e)=>Clipboard.SetText(string.Join(Environment.NewLine,Model.Logs));
}
