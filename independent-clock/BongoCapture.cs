using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.IO;
using System.Text;
using Microsoft.Win32;
using System.Threading;
public static class BongoCapture {
    delegate bool EnumWindowCallback(IntPtr h,IntPtr arg);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowCallback callback,IntPtr arg);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder text,int length);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetProp(IntPtr h,string name);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h,uint command);
    public static IntPtr ProxyWindow(IntPtr source){return GetProp(source,"BongoCat.LayeredProxy");}
    public static IntPtr SourceWindow(IntPtr window){
        if(ProxyWindow(window)!=IntPtr.Zero)return window;
        IntPtr owner=GetWindow(window,4);
        return owner!=IntPtr.Zero&&ProxyWindow(owner)==window?owner:window;
    }
    public static IntPtr FindModelWindow(int pid){
        IntPtr found=IntPtr.Zero;
        EnumWindows((h,arg)=>{
            uint owner;GetWindowThreadProcessId(h,out owner);
            if(owner!=(uint)pid||!IsWindowVisible(h))return true;
            var title=new StringBuilder(128);GetWindowText(h,title,title.Capacity);
            Rect r;
            if(title.ToString()=="BongoCat"&&GetClientRect(h,out r)&&r.Right>32&&r.Bottom>32){found=h;return false;}
            return true;
        },IntPtr.Zero);
        return found;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Rect{public int Left,Top,Right,Bottom;}
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out Rect r);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    public static Bitmap Capture(IntPtr window) {
        IntPtr previous=IntPtr.Zero;
        try{previous=SetThreadDpiAwarenessContext(new IntPtr(-4));}catch(EntryPointNotFoundException){}
        try{return CapturePhysical(window);}finally{if(previous!=IntPtr.Zero)SetThreadDpiAwarenessContext(previous);}
    }
    static Bitmap CapturePhysical(IntPtr window) {
        Rect r;if(!GetClientRect(window,out r)||r.Right<=0||r.Bottom<=0)throw new InvalidOperationException("BongoCat window unavailable");
        var image=new Bitmap(r.Right,r.Bottom,PixelFormat.Format32bppArgb);
        using(var g=Graphics.FromImage(image)){
            g.Clear(Color.White);IntPtr dc=g.GetHdc();bool success;
            try{success=PrintWindow(window,dc,3);}finally{g.ReleaseHdc(dc);}
            if(!success){image.Dispose();throw new InvalidOperationException("BongoCat PrintWindow capture failed");}
        }
        return image;
    }
}
public sealed class BongoSource:IDisposable {
    readonly object sync=new object();
    public string ExecutablePath {get;set;}
    public string Status {get;private set;}
    DateTime nextSearch=DateTime.MinValue;
    IntPtr window;
    IntPtr hiddenProxy,savedRegion;bool hadRegion,hubPriority;
    public bool HubPriority {get{return hubPriority;}set{if(value==hubPriority)return;lock(sync){hubPriority=value;if(!value)RestoreDesktop();}}}
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left,int top,int right,int bottom);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr region);
    [DllImport("user32.dll")] static extern int GetWindowRgn(IntPtr window,IntPtr region);
    [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr window,IntPtr region,bool redraw);
    public void RestoreDesktop(){
        lock(sync){RestoreDesktopLocked();}
    }
    void RestoreDesktopLocked(){
        if(hiddenProxy!=IntPtr.Zero&&IsWindow(hiddenProxy)){
            if(hadRegion){if(SetWindowRgn(hiddenProxy,savedRegion,true)!=0)savedRegion=IntPtr.Zero;}
            else SetWindowRgn(hiddenProxy,IntPtr.Zero,true);
        }
        if(savedRegion!=IntPtr.Zero)DeleteObject(savedRegion);
        hiddenProxy=IntPtr.Zero;savedRegion=IntPtr.Zero;hadRegion=false;
    }
    void HideDesktopProxy(){
        IntPtr proxy=BongoCapture.ProxyWindow(window);
        if(proxy==hiddenProxy&&proxy!=IntPtr.Zero)return;
        RestoreDesktop();
        if(proxy==IntPtr.Zero)throw new InvalidOperationException("当前 BongoCat 不支持独立桌面呈现窗口，无法开启 Hub 优先");
        savedRegion=CreateRectRgn(0,0,0,0);hadRegion=GetWindowRgn(proxy,savedRegion)>0;
        IntPtr empty=CreateRectRgn(0,0,0,0);
        if(SetWindowRgn(proxy,empty,true)==0){DeleteObject(empty);RestoreDesktop();throw new InvalidOperationException("无法隐藏 BongoCat 桌面呈现窗口");}
        hiddenProxy=proxy;
    }
    public void Dispose(){RestoreDesktop();}
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    public static Bitmap Stretch(Bitmap source,int width,int height){
        var result=new Bitmap(width,height,PixelFormat.Format24bppRgb);
        using(var g=Graphics.FromImage(result)){
            g.Clear(Color.Black);g.InterpolationMode=System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.DrawImage(source,new Rectangle(0,0,width,height));
        }
        return result;
    }
    public void Reset(){lock(sync){RestoreDesktop();window=IntPtr.Zero;nextSearch=DateTime.MinValue;}}
    string FindInstalled(){
        foreach(string root in new[]{Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86)})
            foreach(string part in new[]{@"BongoCat\BongoCat.exe",@"Programs\BongoCat\BongoCat.exe"}){string p=Path.Combine(root,part);if(File.Exists(p))return p;}
        foreach(var hive in new[]{Registry.CurrentUser,Registry.LocalMachine})foreach(string key in new[]{@"Software\Microsoft\Windows\CurrentVersion\Uninstall",@"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"}){
            try{using(var parent=hive.OpenSubKey(key)){
                if(parent==null)continue;
                foreach(string name in parent.GetSubKeyNames())using(var item=parent.OpenSubKey(name)){
                    if(item==null||Convert.ToString(item.GetValue("DisplayName")).IndexOf("BongoCat",StringComparison.OrdinalIgnoreCase)<0)continue;
                    string folder=Convert.ToString(item.GetValue("InstallLocation"));
                    if(!String.IsNullOrEmpty(folder)){string p=Path.Combine(folder,"BongoCat.exe");if(File.Exists(p))return p;}
                }
            }}catch{}
        }
        return null;
    }
    public Bitmap Frame(int width,int height){
        lock(sync){return FrameLocked(width,height);}
    }
    Bitmap FrameLocked(int width,int height){
        try{
            if(window==IntPtr.Zero||!IsWindow(window)){
                window=IntPtr.Zero;
                if(DateTime.UtcNow>=nextSearch){
                    nextSearch=DateTime.UtcNow.AddSeconds(3);
                    bool running=false;
                    foreach(var p in Process.GetProcessesByName("BongoCat"))using(p){
                        running=true;
                        IntPtr candidate=BongoCapture.FindModelWindow(p.Id);
                        if(candidate!=IntPtr.Zero){
                            window=BongoCapture.SourceWindow(candidate);
                            try{ExecutablePath=p.MainModule.FileName;}catch{}
                            break;
                        }
                    }
                    if(window==IntPtr.Zero&&!running){
                        if(String.IsNullOrEmpty(ExecutablePath)||!File.Exists(ExecutablePath))ExecutablePath=FindInstalled();
                        if(!String.IsNullOrEmpty(ExecutablePath)&&File.Exists(ExecutablePath)){
                            Process.Start(new ProcessStartInfo(ExecutablePath){WorkingDirectory=Path.GetDirectoryName(ExecutablePath),UseShellExecute=true,WindowStyle=ProcessWindowStyle.Hidden});
                            Status="正在启动 BongoCat…";
                        }else Status="请点击选择 BongoCat，指定已安装的 BongoCat.exe";
                    }else if(window==IntPtr.Zero)Status="请显示 BongoCat 模型窗口";
                }
            }
            if(window!=IntPtr.Zero){
                if(IsIconic(window))Status="请恢复 BongoCat 模型窗口（不要最小化）";
                else{
                    if(hubPriority)HideDesktopProxy();
                    using(var source=BongoCapture.Capture(window)){Status="BongoCat 已连接 · 拉伸铺满";return Stretch(source,width,height);}
                }
            }
        }catch(Exception e){RestoreDesktop();Status="BongoCat: "+e.Message;window=IntPtr.Zero;nextSearch=DateTime.UtcNow.AddSeconds(3);}
        var placeholder=new Bitmap(width,height);
        using(var g=Graphics.FromImage(placeholder))using(var font=new Font("Microsoft YaHei UI",12,FontStyle.Regular,GraphicsUnit.Pixel)){
            g.Clear(Color.FromArgb(13,17,21));g.DrawString(Status??"正在连接 BongoCat…",font,Brushes.White,new RectangleF(12,20,width-24,height-40));
        }
        return placeholder;
    }
}
public sealed class BongoLatestCapture:IDisposable {
    readonly object gate=new object();
    Thread worker;ManualResetEvent stop;Bitmap latest;
    BongoSource source;int width,height;long capturedAt;
    public long Captures {get;private set;}
    public double LastAgeMs {get;private set;}
    public bool IsRunning {get{return worker!=null&&worker.IsAlive;}}
    public void Start(BongoSource input,int w,int h){
        if(IsRunning&&source==input&&width==w&&height==h)return;
        Stop();source=input;width=w;height=h;Captures=0;stop=new ManualResetEvent(false);
        worker=new Thread(Run){IsBackground=true,Name="Hub BongoCat latest capture"};worker.Start();
    }
    void Run(){
        try{
            while(!stop.WaitOne(0)){
                long begin=Stopwatch.GetTimestamp();Bitmap image=source.Frame(width,height);
                lock(gate){if(latest!=null)latest.Dispose();latest=image;capturedAt=Stopwatch.GetTimestamp();Captures++;}
                double elapsed=(Stopwatch.GetTimestamp()-begin)*1000.0/Stopwatch.Frequency;
                if(stop.WaitOne(Math.Max(1,(int)Math.Ceiling(1000.0/60-elapsed))))break;
            }
        }catch{}finally{source.RestoreDesktop();}
    }
    public Bitmap Latest(){
        lock(gate){if(latest==null)return null;LastAgeMs=(Stopwatch.GetTimestamp()-capturedAt)*1000.0/Stopwatch.Frequency;if(LastAgeMs>2000)return null;return (Bitmap)latest.Clone();}
    }
    public void Stop(){
        if(worker!=null){stop.Set();if(!worker.Join(1500))throw new InvalidOperationException("BongoCat capture did not stop; retry after the model window responds");worker=null;stop.Dispose();stop=null;}
        lock(gate){if(latest!=null){latest.Dispose();latest=null;}}
    }
    public void Dispose(){Stop();}
}
