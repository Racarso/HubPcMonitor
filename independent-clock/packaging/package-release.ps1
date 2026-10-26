$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$app=Split-Path $PSScriptRoot;$workspace=Split-Path $app
$version=(Get-Content -Raw -LiteralPath (Join-Path $app 'version.json')|ConvertFrom-Json).Version
& (Join-Path $PSScriptRoot 'build.ps1')
$name='HubPcMonitor-v'+$version+'-Windows-x64'
$directory=Join-Path $workspace ('dist\'+$name)
if(Test-Path -LiteralPath $directory){throw 'Release directory already exists; use a new version or review existing artifacts.'}
$null=New-Item -ItemType Directory -Path $directory
$setupName='HubPcMonitor-v'+$version+'-Setup.exe'
Copy-Item -LiteralPath (Join-Path $workspace 'dist\HubPcMonitor-Setup.exe') -Destination (Join-Path $directory $setupName)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release-README.md') -Destination (Join-Path $directory 'README-使用说明.md')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release-CHANGELOG.md') -Destination (Join-Path $directory 'CHANGELOG.md')
Copy-Item -LiteralPath (Join-Path $app 'version.json') -Destination $directory
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.txt') -Destination $directory
$null=New-Item -ItemType Directory -Path (Join-Path $directory 'licenses')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'COPYING-libusb.txt') -Destination (Join-Path $directory 'licenses')
Copy-Item -LiteralPath (Join-Path $app 'sensors\licenses') -Destination (Join-Path $directory 'licenses\sensors') -Recurse
Copy-Item -LiteralPath (Join-Path $app 'sensors\driver\COPYING.json') -Destination (Join-Path $directory 'licenses\PawnIO-Setup-COPYING.json')
$lines=foreach($file in (Get-ChildItem -LiteralPath $directory -Recurse -File|Sort-Object FullName)){
    (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+$file.FullName.Substring($directory.Length+1).Replace('\','/')
}
[IO.File]::WriteAllLines((Join-Path $directory 'SHA256SUMS.txt'),[string[]]$lines,[Text.UTF8Encoding]::new($false))
$zip=Join-Path $workspace ('dist\'+$name+'.zip')
if(Test-Path -LiteralPath $zip){throw 'Release ZIP already exists'}
[IO.Compression.ZipFile]::CreateFromDirectory($directory,$zip,[IO.Compression.CompressionLevel]::Optimal,$true)
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($zip+'.sha256'),$hash+'  '+[IO.Path]::GetFileName($zip)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $zip|Select-Object FullName,Length
'SHA256: '+$hash
