function Get-HardwareInfo {
    $info = [ordered]@{ CpuName='Unknown'; CpuDisplay='Unknown'; MemoryGiB=$null; MemoryFrequency='Unknown'; MemoryType=''; MemoryDisplay='Unknown'; GpuName='Unknown'; QueryErrors=@() }
    try {
        $names = @(Get-CimInstance Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop | ForEach-Object { $_.Name.Trim() } | Select-Object -Unique)
        if ($names.Count -gt 0) { $info.CpuName=$names -join ' / ' }
    } catch {
        $info.QueryErrors += 'CPU: ' + $_.Exception.Message
        try { $info.CpuName=(Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name ProcessorNameString -ErrorAction Stop).ProcessorNameString.Trim() } catch {}
    }
    $info.CpuDisplay=($info.CpuName -replace '\(R\)|\(TM\)','' -replace '\s+CPU\s+@.*$','' -replace '\s+',' ').Trim()
    try {
        $modules = @(Get-CimInstance Win32_PhysicalMemory -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $_.Capacity -gt 0 })
        if ($modules.Count -gt 0) {
            $info.MemoryGiB=($modules | Measure-Object Capacity -Sum).Sum/1GB
            $freqs=@($modules | ForEach-Object { if ($_.ConfiguredClockSpeed -gt 0) { [int]$_.ConfiguredClockSpeed } } | Sort-Object -Unique)
            if($freqs.Count -gt 0) {
                $info.MemoryFrequency=($freqs -join '/')+' MHz'
                if(@($modules | Where-Object { $_.ConfiguredClockSpeed -le 0 }).Count -gt 0){$info.MemoryFrequency+=' (partial)'}
            }
            $types=@($modules | ForEach-Object { switch ([int]$_.SMBIOSMemoryType) { 24 {'DDR3'} 26 {'DDR4'} 34 {'DDR5'} 27 {'LPDDR'} 28 {'LPDDR2'} 29 {'LPDDR3'} 30 {'LPDDR4'} 35 {'LPDDR5'} default {'RAM'} } } | Select-Object -Unique)
            $info.MemoryType=$types -join '/'
            $info.MemoryDisplay=('{0:0.#} GiB {1} {2}' -f $info.MemoryGiB,$info.MemoryType,$info.MemoryFrequency)
        }
    } catch { $info.QueryErrors += 'Memory: ' + $_.Exception.Message }
    try {
        $gpus=@(Get-CimInstance Win32_VideoController -OperationTimeoutSec 5 -ErrorAction Stop | Where-Object { $_.Name -and $_.Name -notmatch 'Virtual|Remote|Indirect|Mirage|GameViewer' })
        $names=@($gpus | ForEach-Object { $_.Name.Trim() } | Select-Object -Unique)
        if($names.Count -gt 0){$info.GpuName=$names -join ' / '}
    } catch { $info.QueryErrors += 'GPU: ' + $_.Exception.Message }
    return [pscustomobject]$info
}
