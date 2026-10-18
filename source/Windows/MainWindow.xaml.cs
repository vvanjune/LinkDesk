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
 private void Page(string name){ConnectionPage.Visibility=name=="connection"?Visibility.Visible:Visibility.Collapsed;DevicesPage.Visibility=name=="devices"?Visibility.Visible:Visibility.Collapsed;SettingsPage.Visibility=name=="settings"?Visibility.Visible:Visibility.Collapsed;InputPage.Visibility=name=="input"?Visibility.Visible:Visibility.Collapsed;LogsPage.Visibility=name=="logs"?Visibility.Visible:Visibility.Collapsed;PageTitle.Text=name=="connection"?"让工作自然流动":name=="devices"?"配对与选择设备":name=="settings"?"按你的习惯运行":name=="input"?"熟悉的按键，顺手的滚动":"连接日志";PageSubtitle.Text=name=="connection"?"把注意力留给工作，让键鼠跟随你。":name=="devices"?"连接所选电脑，身份由完整指纹确认。":name=="settings"?"设置一次，以后轻松连接。":name=="input"?"按键映射与滚动设置，在这里一起调整。":"这里记录真实的连接与错误信息。";}
 private void ShowConnection(object s,RoutedEventArgs e)=>Page("connection");
 private void ShowDevices(object s,RoutedEventArgs e)=>Page("devices");
 private void ShowSettings(object s,RoutedEventArgs e)=>Page("settings");
 private void RefreshDevices(object s,RoutedEventArgs e)=>Model.RefreshDiscovery();
 private void ChooseDevice(object s,RoutedEventArgs e){if(s is System.Windows.Controls.Button {Tag:string id})Model.SelectDevice(id);}
 private void AddManualDevice(object s,RoutedEventArgs e)=>Model.AddManualDevice();
 private void ForgetDevice(object s,RoutedEventArgs e){if(s is System.Windows.Controls.Button {Tag:string id}&&MessageBox.Show("忘记后将撤销配对；再次连接需要重新核对完整指纹。","忘记设备？",MessageBoxButton.YesNo,MessageBoxImage.Question)==MessageBoxResult.Yes)Model.ForgetDevice(id);}
 private void RenameDevice(object s,RoutedEventArgs e){
  if(s is not System.Windows.Controls.Button {Tag:string id})return;
  var peer=Model.Devices.FirstOrDefault(d=>d.Id==id);if(peer is null)return;
  var dialog=new Window{Owner=this,Title="设备备注名称",Width=440,Height=220,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterOwner,Background=System.Windows.Media.Brushes.White};
  var stack=new System.Windows.Controls.StackPanel{Margin=new Thickness(24)};
  var box=new System.Windows.Controls.TextBox{Text=peer.Label,Margin=new Thickness(0,12,0,14),Padding=new Thickness(10)};
  stack.Children.Add(new System.Windows.Controls.TextBlock{Text="只改变本机列表中的备注，指纹保持不变。",TextWrapping=TextWrapping.Wrap});stack.Children.Add(box);
  var save=new System.Windows.Controls.Button{Content="保存",Padding=new Thickness(20,8,20,8),HorizontalAlignment=HorizontalAlignment.Right};save.Click+=(_,_)=>{Model.RenameDevice(id,box.Text);dialog.Close();};stack.Children.Add(save);dialog.Content=stack;dialog.ShowDialog();
 }
 private void UpdateDeviceAddress(object s,RoutedEventArgs e){
  if(s is not System.Windows.Controls.Button {Tag:string id})return;
  if(Model.SelectedDevice?.Id!=id){MessageBox.Show("请先选择这台已配对设备，再更新地址。","LinkDesk");return;}
  var dialog=new Window{Owner=this,Title="更新设备地址",Width=460,SizeToContent=SizeToContent.Height,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterOwner};
  var stack=new System.Windows.Controls.StackPanel{Margin=new Thickness(24)};
  stack.Children.Add(new System.Windows.Controls.TextBlock{Text="填写对方连接页显示的 IP 地址或主机名。配对身份不变，连接时仍会核对原有指纹；自动发现仍可更新地址。",TextWrapping=TextWrapping.Wrap});
  var box=new System.Windows.Controls.TextBox{Text=Model.Host,Margin=new Thickness(0,16,0,16),Padding=new Thickness(10)};stack.Children.Add(box);
  var save=new System.Windows.Controls.Button{Content="保存地址",HorizontalAlignment=HorizontalAlignment.Right,Padding=new Thickness(20,8,20,8)};
  save.Click+=(_,_)=>{try{Model.UpdateSelectedAddress(id,box.Text);dialog.Close();}catch(Exception error){MessageBox.Show(dialog,error.Message,"地址未更新");}};
  stack.Children.Add(save);dialog.Content=stack;dialog.ShowDialog();
 }
 private void ShowLogs(object s,RoutedEventArgs e)=>Page("logs");
 private void ShowInput(object s,RoutedEventArgs e)=>Page("input");
 private void MacMapping(object s,RoutedEventArgs e)=>Model.MappingPreset(true);
 private void OriginalMapping(object s,RoutedEventArgs e)=>Model.MappingPreset(false);
 private void ResetScrolling(object s,RoutedEventArgs e)=>Model.ResetScrolling();
 private void SaveInput(object s,RoutedEventArgs e){try{_=InputConfiguration.Mapping(Model.MapSuper,Model.MapControl,Model.MapOption,Model.MapShift);_=InputConfiguration.Scrolling(Model.InvertVertical,Model.InvertHorizontal,Model.VerticalSpeed,Model.HorizontalSpeed);_=InputConfiguration.SwitchDelay(int.Parse(Model.SwitchDelayChoice));bool wasRunning=Model.Running;Model.SaveAndApply();MessageBox.Show(wasRunning?"已保存，正在重新加载共享连接。":"已保存，下次启动共享时生效。","LinkDesk");}catch(Exception error){MessageBox.Show(error.Message,"LinkDesk");}}
 private void ToggleConnection(object s,RoutedEventArgs e){if(!Model.Running&&Model.SelectedDevice is null){Page("devices");return;}Model.Toggle();}
 private void ConnectionOptionChanged(object s,System.Windows.Controls.SelectionChangedEventArgs e){if(IsLoaded)Dispatcher.BeginInvoke(()=>Model.SaveAndApply());}
 private void SaveSettings(object s,RoutedEventArgs e){bool wasRunning=Model.Running;Model.SaveAndApply();Model.PropertyChangedForAddress();MessageBox.Show(wasRunning?"已保存，正在重新加载共享连接。":"已保存，下次启动连接时生效。","LinkDesk");}
 private void CopyLogs(object s,RoutedEventArgs e)=>Clipboard.SetText(string.Join(Environment.NewLine,Model.Logs));
}
