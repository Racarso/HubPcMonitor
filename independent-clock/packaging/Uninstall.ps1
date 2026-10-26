$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\HubPcMonitor'))
if([IO.Path]::GetFullPath($PSScriptRoot) -ne $root){throw 'Unexpected installation path; removal cancelled.'}
if([Windows.Forms.MessageBox]::Show('Remove Hub PC Monitor and its automatic startup entry?','Hub PC Monitor','YesNo','Question') -ne 'Yes'){exit}
if((Get-Service HubPcMonitorSensors -ErrorAction SilentlyContinue) -and [Windows.Forms.MessageBox]::Show('Also remove the system temperature collection service? Administrator approval is required. The shared PawnIO driver will remain installed.','Temperature component','YesNo','Question') -eq 'Yes'){
    $info=[Diagnostics.ProcessStartInfo]::new('powershell.exe',('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Install-Sensors.ps1')+'" -Remove'))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($info);$p.WaitForExit()
    if($p.ExitCode -ne 0){throw 'Temperature service removal canceled or failed'}
}
$instance='Local\HubPcMonitor.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
try{$event=[Threading.EventWaitHandle]::OpenExisting($instance+'.Exit');$null=$event.Set();$event.Dispose()}catch [Threading.WaitHandleCannotBeOpenedException]{}
$gate=[Threading.Mutex]::new($false,$instance);$acquired=$false
try{
    try{$acquired=$gate.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){throw 'Exit the tray application before uninstalling.'}
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name HubPcMonitor -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HubPcMonitor' -Recurse -Force -ErrorAction SilentlyContinue
    $shortcut=Join-Path ([Environment]::GetFolderPath('Programs')) 'Hub PC Monitor.lnk'
    if(Test-Path -LiteralPath $shortcut){Remove-Item -LiteralPath $shortcut -Force}
    # Setup.exe exits immediately after starting this script; allow it to release its file.
    for($attempt=0;$attempt -lt 20;$attempt++){
        try{Remove-Item -LiteralPath (Join-Path $root 'Setup.exe') -Force -ErrorAction Stop;break}catch{Start-Sleep -Milliseconds 250}
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Uninstall failed')|Out-Null;exit 1}
finally{if($acquired){$gate.ReleaseMutex()};$gate.Dispose()}
