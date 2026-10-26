param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$SetupPath,[switch]$AutoStart,[switch]$Launch,[switch]$InstallSensors)
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'Programs\HubPcMonitor'
$instance='Local\HubPcMonitor.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
try {$exitEvent=[Threading.EventWaitHandle]::OpenExisting($instance+'.Exit');$null=$exitEvent.Set();$exitEvent.Dispose()}catch [Threading.WaitHandleCannotBeOpenedException]{}
$gate=[Threading.Mutex]::new($false,$instance)
$acquired=$false
try {
    try{$acquired=$gate.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){throw 'Please exit Hub PC Monitor from its tray menu and retry installation.'}
    $null=New-Item -ItemType Directory -Path $root -Force
    foreach($name in @('version.json','clock.ps1','HardwareInfo.ps1','PerformanceSampler.cs','CpuFrequency.ps1','cpu-frequency-profiles.json','TemperatureSampler.cs','Install-Sensors.ps1','UsbClock.cs','CodexQuota.cs','OriginalArtwork.cs','ScreenOrientation.cs','BongoCapture.cs','AnimationFramePump.cs','AudioSpectrum.cs','HubMonitor.exe','HubMonitor.ico','Uninstall.ps1','THIRD-PARTY-NOTICES.txt','COPYING-libusb.txt')) {
        Copy-Item -LiteralPath (Join-Path $Source $name) -Destination (Join-Path $root $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path $Source 'sensors') -Destination $root -Recurse -Force
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'native') -Force
    Copy-Item -LiteralPath (Join-Path $Source 'native\libusb-1.0.dll') -Destination (Join-Path $root 'native\libusb-1.0.dll') -Force
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'assets') -Force
    Copy-Item -LiteralPath (Join-Path $Source 'assets\deepseek-clock.png') -Destination (Join-Path $root 'assets\deepseek-clock.png') -Force
    Copy-Item -LiteralPath (Join-Path $Source 'assets\chatgpt-source.jfif') -Destination (Join-Path $root 'assets\chatgpt-source.jfif') -Force
    Copy-Item -LiteralPath (Join-Path $Source 'assets\zh-CN.json') -Destination (Join-Path $root 'assets\zh-CN.json') -Force
    if(-not(Test-Path -LiteralPath (Join-Path $root 'device-profiles.json'))){Copy-Item -LiteralPath (Join-Path $Source 'device-profiles.json') -Destination (Join-Path $root 'device-profiles.json')}
    Copy-Item -LiteralPath $SetupPath -Destination (Join-Path $root 'Setup.exe') -Force
    $run='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $null=New-Item -Path $run -Force
    if($AutoStart){$null=New-ItemProperty -Path $run -Name HubPcMonitor -Value ('"'+(Join-Path $root 'HubMonitor.exe')+'" --tray') -PropertyType String -Force}
    else{Remove-ItemProperty -Path $run -Name HubPcMonitor -ErrorAction SilentlyContinue}
    $uninstall='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\HubPcMonitor'
    $null=New-Item -Path $uninstall -Force
    $values=@{DisplayName='Hub PC Monitor';DisplayVersion=([IO.File]::ReadAllText((Join-Path $Source 'version.json'))|ConvertFrom-Json).Version;Publisher='Hub PC Monitor';InstallLocation=$root;DisplayIcon=(Join-Path $root 'HubMonitor.exe');UninstallString=('"'+(Join-Path $root 'Setup.exe')+'" /uninstall')}
    foreach($key in $values.Keys){$null=New-ItemProperty -Path $uninstall -Name $key -Value $values[$key] -PropertyType String -Force}
    $null=New-ItemProperty -Path $uninstall -Name NoModify -Value 1 -PropertyType DWord -Force
    $null=New-ItemProperty -Path $uninstall -Name NoRepair -Value 1 -PropertyType DWord -Force
    $shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Hub PC Monitor.lnk'))
    $link.TargetPath=Join-Path $root 'HubMonitor.exe';$link.WorkingDirectory=$root;$link.Save()
}finally{if($acquired){$gate.ReleaseMutex()};$gate.Dispose()}
if($InstallSensors){
    $info=[Diagnostics.ProcessStartInfo]::new('powershell.exe',('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'Install-Sensors.ps1')+'"'))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $p=[Diagnostics.Process]::Start($info);$p.WaitForExit();if($p.ExitCode -ne 0){throw 'Temperature component installation failed or was canceled'}
}
if($Launch){Start-Process -FilePath (Join-Path $root 'HubMonitor.exe') -ArgumentList '--tray' -WindowStyle Hidden}
