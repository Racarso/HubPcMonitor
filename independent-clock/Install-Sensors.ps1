param([switch]$Elevated,[switch]$Remove)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$admin=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin){
    if($Elevated){throw 'Administrator permission required'}
    $info=[Diagnostics.ProcessStartInfo]::new('powershell.exe',('-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Elevated'+$(if($Remove){' -Remove'}else{''})))
    $info.UseShellExecute=$true;$info.Verb='runas';$info.WindowStyle='Hidden'
    $p=[Diagnostics.Process]::Start($info);$p.WaitForExit();exit $p.ExitCode
}
try{
    $target=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'HubPcMonitorSensors'))
    $data=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'HubPcMonitorSensors'))
    foreach($directory in @($target,$data)){
        if((Test-Path -LiteralPath $directory) -and ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected sensor directory link'}
    }
    if($Remove){
        if(Get-Service HubPcMonitorSensors -ErrorAction SilentlyContinue){
            Stop-Service HubPcMonitorSensors -ErrorAction SilentlyContinue
            (Get-Service HubPcMonitorSensors).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))
            & sc.exe delete HubPcMonitorSensors | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Could not remove temperature service'}
        }
        foreach($directory in @($target,$data)){
            if((Split-Path $directory -Leaf) -ne 'HubPcMonitorSensors'){throw 'Unexpected removal target'}
            if(Test-Path -LiteralPath $directory){Remove-Item -LiteralPath $directory -Recurse -Force}
        }
        exit 0
    }
    $source=Join-Path $PSScriptRoot 'sensors'
    $driver=Join-Path $source 'driver\PawnIO_setup.exe'
    $hash=(Get-FileHash -LiteralPath $driver -Algorithm SHA256).Hash
    if($hash -ne '1F519A22E47187F70A1379A48CA604981C4FCF694F4E65B734AAA74A9FBA3032'){throw 'PawnIO package hash mismatch'}
    $sig=Get-AuthenticodeSignature -LiteralPath $driver
    if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'CN=namazso\.eu(?:,|$)'){throw 'PawnIO signature verification failed'}
    foreach($directory in @($target,$data)){
        $null=New-Item -ItemType Directory -Path $directory -Force
        $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        foreach($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($entry[0]),$entry[1],'ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $directory -AclObject $acl
    }
    $existing=Get-Service HubPcMonitorSensors -ErrorAction SilentlyContinue
    if($existing -and $existing.Status -ne 'Stopped'){Stop-Service HubPcMonitorSensors; (Get-Service HubPcMonitorSensors).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))}
    foreach($file in Get-ChildItem -LiteralPath $source -File -Filter '*.dll'){Copy-Item -LiteralPath $file.FullName -Destination $target -Force}
    Copy-Item -LiteralPath (Join-Path $source 'HubSensorService.exe') -Destination $target -Force
    Copy-Item -LiteralPath $driver -Destination (Join-Path $target 'PawnIO_setup.exe') -Force
    Copy-Item -LiteralPath (Join-Path $source 'licenses') -Destination $target -Recurse -Force
    if(-not (Get-Service PawnIO -ErrorAction SilentlyContinue)){
        $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $target 'PawnIO_setup.exe'),'-install -silent');$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $p=[Diagnostics.Process]::Start($info);$p.WaitForExit()
        if($p.ExitCode -eq 3010){throw 'PawnIO installed; restart Windows, then run temperature component setup again'}
        if(-not (Get-Service PawnIO -ErrorAction SilentlyContinue)){throw ('PawnIO installation failed: '+$p.ExitCode)}
    }
    $binary='"'+(Join-Path $target 'HubSensorService.exe')+'"'
    if(-not $existing){$null=New-Service -Name HubPcMonitorSensors -BinaryPathName $binary -DisplayName 'Hub PC Monitor Temperature Sensors' -StartupType Automatic -Description 'Reads CPU/GPU temperatures for Hub PC Monitor. Publishes read-only temperature data.'}
    else{& sc.exe config HubPcMonitorSensors binPath= $binary start= auto | Out-Null;if($LASTEXITCODE -ne 0){throw 'Service configuration failed'}}
    Start-Service HubPcMonitorSensors
    Set-Content -LiteralPath (Join-Path $data 'install-status.txt') -Value ((Get-Date).ToString('o')+' Installed')
}catch{
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
