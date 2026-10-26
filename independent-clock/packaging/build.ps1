$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
$app=Split-Path $PSScriptRoot
$version=([IO.File]::ReadAllText((Join-Path $app 'version.json'))|ConvertFrom-Json).Version
if($version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid release version'}
$workspace=Split-Path $app
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw '64-bit .NET Framework C# compiler missing.'}
$stage=Join-Path $PSScriptRoot ('stage-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $stage 'native') -Force
$assemblyInfo=Join-Path $stage 'AssemblyInfo.cs'
[IO.File]::WriteAllText($assemblyInfo,('[assembly:System.Reflection.AssemblyVersion("'+$version+'.0")][assembly:System.Reflection.AssemblyFileVersion("'+$version+'.0")][assembly:System.Reflection.AssemblyProduct("Hub PC Monitor")][assembly:System.Reflection.AssemblyTitle("Hub PC Monitor")]'))
$output=Join-Path $workspace 'dist'
$null=New-Item -ItemType Directory -Path $output -Force
$iconPath=Join-Path $app 'HubMonitor.ico'
$bitmap=[Drawing.Bitmap]::new(32,32)
$g=[Drawing.Graphics]::FromImage($bitmap)
$yellow=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#F4D35E'))
try{
    $g.Clear([Drawing.ColorTranslator]::FromHtml('#0D1115'))
    $g.FillRectangle($yellow,6,19,5,7);$g.FillRectangle($yellow,14,12,5,14);$g.FillRectangle($yellow,22,6,5,20)
    $icon=[Drawing.Icon]::FromHandle($bitmap.GetHicon())
    $stream=[IO.File]::Create($iconPath)
    try{$icon.Save($stream)}finally{$stream.Dispose()}
}finally{$g.Dispose();$yellow.Dispose();$bitmap.Dispose()}
Copy-Item -LiteralPath $iconPath -Destination $stage
& $compiler /nologo /target:exe /platform:x64 /r:System.ServiceProcess.dll /r:System.Web.Extensions.dll (('/out:')+(Join-Path $app 'sensors\HubSensorService.exe')) (Join-Path $PSScriptRoot 'SensorService.cs') (Join-Path $app 'TemperatureSampler.cs')
if($LASTEXITCODE -ne 0){throw 'Sensor service compilation failed.'}
$null=New-Item -ItemType Directory -Path (Join-Path $stage 'sensors') -Force
foreach($file in (Get-ChildItem -LiteralPath (Join-Path $app 'sensors') -File|Where-Object {$_.Extension -eq '.dll' -or $_.Name -eq 'HubSensorService.exe'})){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stage 'sensors')}
Copy-Item -LiteralPath (Join-Path $app 'sensors\licenses') -Destination (Join-Path $stage 'sensors') -Recurse
$null=New-Item -ItemType Directory -Path (Join-Path $stage 'sensors\driver') -Force
foreach($file in @('PawnIO_setup.exe','COPYING.json')){Copy-Item -LiteralPath (Join-Path $app ('sensors\driver\'+$file)) -Destination (Join-Path $stage 'sensors\driver')}
Copy-Item -LiteralPath (Join-Path $app 'version.json') -Destination $stage
foreach($name in @('clock.ps1','UsbClock.cs','PerformanceSampler.cs','CpuFrequency.ps1','cpu-frequency-profiles.json','TemperatureSampler.cs','Install-Sensors.ps1','HardwareInfo.ps1','CodexQuota.cs','OriginalArtwork.cs','ScreenOrientation.cs','BongoCapture.cs','AnimationFramePump.cs','AudioSpectrum.cs')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination $stage}
$null=New-Item -ItemType Directory -Path (Join-Path $stage 'assets') -Force
foreach($asset in @('deepseek-clock.png','chatgpt-source.jfif','zh-CN.json')){Copy-Item -LiteralPath (Join-Path $app ('assets\'+$asset)) -Destination (Join-Path $stage ('assets\'+$asset))}
[IO.File]::WriteAllText((Join-Path $stage 'device-profiles.json'),'{}')
foreach($name in @('Install.ps1','Uninstall.ps1','THIRD-PARTY-NOTICES.txt','COPYING-libusb.txt')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $stage}
$usbLibrary=Join-Path $app 'native\libusb-1.0.dll'
if(-not(Test-Path -LiteralPath $usbLibrary)){throw 'Bundled native/libusb-1.0.dll is missing; restore repository dependencies.'}
Copy-Item -LiteralPath $usbLibrary -Destination (Join-Path $stage 'native\libusb-1.0.dll')
& $compiler /nologo /target:winexe /platform:x64 /r:System.Windows.Forms.dll (('/win32icon:')+$iconPath) (('/out:')+(Join-Path $stage 'HubMonitor.exe')) (Join-Path $PSScriptRoot 'Launcher.cs') $assemblyInfo
if($LASTEXITCODE -ne 0){throw 'Launcher compilation failed.'}
$payload=Join-Path $PSScriptRoot ('payload-'+[guid]::NewGuid().ToString('N')+'.zip')
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$payload)
$setup=Join-Path $output 'HubPcMonitor-Setup.exe'
& $compiler /nologo /target:winexe /platform:x64 /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll (('/win32icon:')+$iconPath) (('/resource:')+$payload+',Payload.zip') (('/out:')+$setup) (Join-Path $PSScriptRoot 'Setup.cs') $assemblyInfo
if($LASTEXITCODE -ne 0){throw 'Setup compilation failed.'}
Get-Item -LiteralPath $setup | Select-Object FullName,Length
Get-FileHash -LiteralPath $setup -Algorithm SHA256
