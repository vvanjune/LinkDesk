using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
namespace LinkDesk;

public readonly record struct DesktopSnapshot(bool Ready,string Signature);

public static class WindowsDesktopState {
 [StructLayout(LayoutKind.Sequential)] private struct Luid {public uint Low;public int High;}
 [StructLayout(LayoutKind.Sequential)] private struct Rational {public uint Numerator,Denominator;}
 [StructLayout(LayoutKind.Sequential)] private struct Source {public Luid Adapter;public uint Id,Mode,Flags;}
 [StructLayout(LayoutKind.Sequential)] private struct Target {
  public Luid Adapter;public uint Id,Mode;public int Technology,Rotation,Scaling;
  public Rational Refresh;public int Scanline;
  [MarshalAs(UnmanagedType.Bool)] public bool Available;
  public uint Flags;
 }
 [StructLayout(LayoutKind.Sequential)] private struct DisplayPath {public Source Source;public Target Target;public uint Flags;}
 [DllImport("user32.dll")] private static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
 [DllImport("user32.dll")] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CloseDesktop(IntPtr desktop);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool GetUserObjectInformation(IntPtr obj,int index,StringBuilder value,uint length,out uint needed);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr FindWindow(string className,string? title);
 [DllImport("user32.dll")] private static extern int GetDisplayConfigBufferSizes(uint flags,out uint paths,out uint modes);
 [DllImport("user32.dll")] private static extern int QueryDisplayConfig(uint flags,ref uint paths,[In,Out] DisplayPath[] values,ref uint modes,IntPtr modeValues,IntPtr topology);
 public static DesktopSnapshot Read() {
  var desktop=OpenInputDesktop(0,false,1);
  if(desktop==IntPtr.Zero)return new(false,"");
  try {
   var name=new StringBuilder(256);
   if(!GetUserObjectInformation(desktop,2,name,512,out _)||name.ToString()!="Default"||FindWindow("Progman",null)==IntPtr.Zero)return new(false,"");
  }finally{CloseDesktop(desktop);}
  const uint active=2;
  if(GetDisplayConfigBufferSizes(active,out uint paths,out uint modes)!=0||paths==0||paths>256||modes>512)return new(false,"");
  var values=new DisplayPath[paths];var buffer=Marshal.AllocHGlobal(checked((int)Math.Max(modes,1)*64));
  try {
   if(QueryDisplayConfig(active,ref paths,values,ref modes,buffer,IntPtr.Zero)!=0)return new(false,"");
   var physical=values.Take((int)paths).Where(p=>(p.Flags&1)!=0&&p.Target.Available&&p.Target.Technology is not (-1 or 15 or 16 or 17)).ToArray();
   if(physical.Length==0)return new(false,"");
   var signature=string.Join(";",physical.Select(p=>$"{p.Source.Adapter.High}:{p.Source.Adapter.Low}:{p.Source.Id}:{p.Source.Mode}:{p.Target.Id}:{p.Target.Technology}:{p.Target.Rotation}:{p.Target.Scaling}:{p.Target.Refresh.Numerator}/{p.Target.Refresh.Denominator}").Order());
   return new(true,signature);
  }finally{Marshal.FreeHGlobal(buffer);}
 }
 public static int DisplayPathSize=>Marshal.SizeOf<DisplayPath>();
}
