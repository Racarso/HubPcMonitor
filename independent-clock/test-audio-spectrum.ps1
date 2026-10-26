param([switch]$Live)
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'AudioSpectrum.cs') -ReferencedAssemblies @('System.Drawing.dll','System.dll')
$silence=[AudioSpectrum]::Analyze([double[]]::new(2048),48000)
if(($silence|Measure-Object -Maximum).Maximum -ne 0){throw 'Silence generated a spectrum'}
$samples=[double[]]::new(2048)
for($i=0;$i -lt 2048;$i++){$samples[$i]=.25*[Math]::Sin(2*[Math]::PI*1000*$i/48000)}
$bins=[AudioSpectrum]::Analyze($samples,48000)
$peak=0;for($i=1;$i -lt 24;$i++){if($bins[$i] -gt $bins[$peak]){$peak=$i}}
if($peak -lt 11 -or $peak -gt 13 -or $bins[$peak] -lt .5){throw "1000 Hz FFT peak wrong: $peak"}
'PASS: silence and 1000 Hz logarithmic FFT bands'
if($Live){
    # Short, low-volume generated tone validates actual playback-loopback capture.
    $stream=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($stream)
    $size=48000*2*2
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([int](36+$size));$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([int]16);$writer.Write([int16]1);$writer.Write([int16]1);$writer.Write([int]48000);$writer.Write([int]96000);$writer.Write([int16]2);$writer.Write([int16]16);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([int]$size)
    for($i=0;$i -lt 96000;$i++){$writer.Write([int16](1800*[Math]::Sin(2*[Math]::PI*1000*$i/48000)))}
    $stream.Position=0;$player=[Media.SoundPlayer]::new($stream);$audio=[AudioSpectrum]::new()
    try{
        $player.Load();$audio.Start();Start-Sleep -Milliseconds 700;$player.PlayLooping();Start-Sleep -Milliseconds 1200
        $captured=$audio.Snapshot();$maximum=($captured|Measure-Object -Maximum).Maximum
        if($audio.Status -ne 'LIVE' -or $audio.CapturedFrames -le 0){throw "Loopback stream failed: $($audio.Status)"}
        "PASS: real loopback stream supplies frames, $($audio.Format)"
        if($audio.OutputVolume -match 'volume=0,|muted=True'){'SKIP: audible tone response; default playback is muted or volume is zero'}
        elseif($maximum -lt .05){throw "Loopback tone test failed: maximum=$maximum, peak=$($audio.SamplePeak), $($audio.OutputVolume)"}
        else{"PASS: real default playback tone response, maximum=$maximum"}
        $player.Stop();$audio.Stop();$audio.Start();Start-Sleep -Milliseconds 300;$audio.Stop();'PASS: capture stop/restart'
    }finally{$player.Stop();$audio.Dispose();$player.Dispose();$writer.Dispose();$stream.Dispose()}
}
