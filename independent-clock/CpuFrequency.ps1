function Find-CpuFrequencyProfile([string]$CpuName,[string]$Path=(Join-Path $PSScriptRoot 'cpu-frequency-profiles.json')) {
    if(-not $CpuName -or $CpuName.Contains(' / ')){return $null}
    try{
        $table=Get-Content -Raw -Encoding UTF8 -LiteralPath $Path|ConvertFrom-Json
        $matches=@($table.Profiles|Where-Object {$CpuName -match $_.Pattern})
        if($matches.Count -ne 1){return $null}
        $profile=$matches[0]
        if([double]$profile.BaseGhz -le 0 -or [double]$profile.MaxTurboGhz -le [double]$profile.BaseGhz -or [double]$profile.MaxTurboGhz -gt 20){return $null}
        return $profile
    }catch{return $null}
}
