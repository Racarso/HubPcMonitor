using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;
class Launcher {
 [STAThread] static void Main(string[] args){
  try {
   string root=AppDomain.CurrentDomain.BaseDirectory;
   string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),@"System32\WindowsPowerShell\v1.0\powershell.exe");
   var start=new ProcessStartInfo(ps,"-NoProfile -ExecutionPolicy Bypass -STA -File \""+Path.Combine(root,"clock.ps1")+"\" -Model Auto"+(Array.IndexOf(args,"--tray")>=0?" -Tray":""));
   start.UseShellExecute=false;start.CreateNoWindow=true;start.WorkingDirectory=root;
   Process.Start(start);
  }catch(Exception e){MessageBox.Show(e.Message,"Hub PC Monitor");}
 }
}
