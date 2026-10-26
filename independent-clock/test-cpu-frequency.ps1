$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'PerformanceSampler.cs')
. (Join-Path $PSScriptRoot 'CpuFrequency.ps1')
$table=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'cpu-frequency-profiles.json')|ConvertFrom-Json
foreach($entry in $table.Profiles){
    $found=Find-CpuFrequencyProfile $entry.Model
    if(-not $found -or $found.Model -ne $entry.Model){throw ('Model failed '+$entry.Model)}
    $mid=($entry.BaseGhz+$entry.MaxTurboGhz)/2
    if([Math]::Abs([PcLoadReader]::FrequencyRangePercent($mid,$entry.BaseGhz,$entry.MaxTurboGhz)-50) -gt .001){throw 'Midpoint failed'}
}
$profile=Find-CpuFrequencyProfile 'Intel(R) Core(TM) i7-4790 CPU @ 3.60GHz'
$reader=[PcLoadReader]::new()
try{
    $null=$reader.Poll();Start-Sleep -Seconds 3;$sample=$reader.Poll()
    if($null -eq $sample.CpuGhz){throw 'CPU current frequency unavailable'}
    [pscustomobject]@{Model=$profile.Model;BaseGhz=$profile.BaseGhz;TurboGhz=$profile.MaxTurboGhz;CurrentGhz=$sample.CpuGhz;RangePercent=[PcLoadReader]::FrequencyRangePercent($sample.CpuGhz,$profile.BaseGhz,$profile.MaxTurboGhz);GpuPercent=$sample.GpuPercent}|ConvertTo-Json
}finally{$reader.Dispose()}
'PASS: all model profiles, midpoint arithmetic and live CPU range'
