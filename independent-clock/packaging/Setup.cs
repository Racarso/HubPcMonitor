using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;
class Setup {
 static string Ps {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe");}}
 static string Quote(string value){return "\""+value+"\"";}
 static void Install(bool startup,bool launch,bool sensors){
  string temp=Path.Combine(Path.GetTempPath(),"HubPcMonitorSetup",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(temp);
  try {
   using(var resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload.zip"))
   using(var zip=new ZipArchive(resource,ZipArchiveMode.Read))foreach(var entry in zip.Entries){
    string path=Path.GetFullPath(Path.Combine(temp,entry.FullName));
    if(!path.StartsWith(temp+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new Exception("Invalid package path.");
    Directory.CreateDirectory(Path.GetDirectoryName(path));entry.ExtractToFile(path);
   }
   string arguments="-NoProfile -ExecutionPolicy Bypass -File "+Quote(Path.Combine(temp,"Install.ps1"))+" -Source "+Quote(temp)+" -SetupPath "+Quote(Assembly.GetExecutingAssembly().Location)+(startup?" -AutoStart":"")+(launch?" -Launch":"")+(sensors?" -InstallSensors":"");
   var p=Process.Start(new ProcessStartInfo(Ps,arguments){UseShellExecute=false,CreateNoWindow=true});p.WaitForExit();if(p.ExitCode!=0)throw new Exception("Installation failed. Close the tray application and retry.");
  }finally{Directory.Delete(temp,true);}
 }
 [STAThread] static int Main(string[] args){
  Application.EnableVisualStyles();
  try {
   if(Array.IndexOf(args,"/uninstall")>=0){string root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"Programs\HubPcMonitor");Process.Start(new ProcessStartInfo(Ps,"-NoProfile -ExecutionPolicy Bypass -STA -File "+Quote(Path.Combine(root,"Uninstall.ps1"))){UseShellExecute=false,CreateNoWindow=true});return 0;}
   if(Array.IndexOf(args,"/quiet")>=0){Install(true,true,Array.IndexOf(args,"/sensors")>=0);return 0;}
   var f=new Form{Text="Hub PC Monitor v"+Assembly.GetExecutingAssembly().GetName().Version.ToString(3)+" Setup",ClientSize=new Size(510,275),FormBorderStyle=FormBorderStyle.FixedDialog,MaximizeBox=false,StartPosition=FormStartPosition.CenterScreen,Font=new Font("Segoe UI",9)};
   var title=new Label{Text="Install Hub PC Monitor",Left=22,Top=20,Width=460,Height=30,Font=new Font("Segoe UI",16)};
   var note=new Label{Text="Direct USB monitoring with a system tray icon.\nThe optional CPU temperature component requires administrator approval.",Left=24,Top=60,Width=460,Height=40};
   var startup=new CheckBox{Text="Start automatically when I sign in",Checked=true,Left=24,Top=112,Width=450};
   var launch=new CheckBox{Text="Launch in system tray after installation",Checked=true,Left=24,Top=143,Width=450};
   var sensors=new CheckBox{Text="安装 CPU 温度组件（PawnIO + 后台采集服务，需要管理员权限）",Checked=true,Left=24,Top=174,Width=470};
   var install=new Button{Text="Install",Left=367,Top=225,Width=115,Height=32};
   install.Click+=delegate{try{install.Enabled=false;Install(startup.Checked,launch.Checked,sensors.Checked);MessageBox.Show("Installed. Right-click the tray icon and choose Exit to quit.","Hub PC Monitor");f.Close();}catch(Exception e){MessageBox.Show(e.Message,"Setup error");install.Enabled=true;}};
   f.Controls.AddRange(new Control[]{title,note,startup,launch,sensors,install});Application.Run(f);return 0;
  }catch(Exception e){MessageBox.Show(e.Message,"Hub PC Monitor Setup");return 1;}
 }
}
