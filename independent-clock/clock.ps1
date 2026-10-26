param([switch]$SelfTest, [switch]$Probe, [switch]$SampleOnly, [switch]$QuotaOnly, [switch]$QueryChatGPTBalance, [switch]$Tray, [int]$RunSeconds = 0, [string]$Serial = '', [ValidateSet('Auto','V1PRO','V2')][string]$Model='Auto', [ValidateSet('Clock','Monitor','DeepSeek','ChatGPT','BongoCat','Spectrum')][string]$Mode='Monitor', [ValidateSet('None','Full','Region')][string]$Benchmark='None')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'AnimationFramePump.cs') -ReferencedAssemblies @('System.Windows.Forms.dll','System.dll')
Add-Type -Path (Join-Path $PSScriptRoot 'BongoCapture.cs') -ReferencedAssemblies @('System.Drawing.dll','System.dll','System.Core.dll')
Add-Type -Path (Join-Path $PSScriptRoot 'AudioSpectrum.cs') -ReferencedAssemblies @('System.Drawing.dll','System.dll')
$audioSpectrum=[AudioSpectrum]::new();$spectrumRenderer=[TacticalSpectrum]::new()
$bongoSource=[BongoSource]::new()
$bongoPipeline=[BongoLatestCapture]::new()
$script:bongoParallel=$true
$script:bongoSmooth=$true
$script:bongoReduceColor=$true
$script:bongoHubPriority=$true
$script:bongoZoned=$true
Add-Type -Path (Join-Path $PSScriptRoot 'ScreenOrientation.cs') -ReferencedAssemblies System.Drawing
$script:rotation=0
Add-Type -Path (Join-Path $PSScriptRoot 'UsbClock.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'PerformanceSampler.cs')
$loadReader=[PcLoadReader]::new();$script:loads=[PcLoadSnapshot]::new()
Add-Type -Path (Join-Path $PSScriptRoot 'TemperatureSampler.cs') -ReferencedAssemblies @('System.Web.Extensions.dll','System.dll','System.Core.dll')
$temperatureReader=[TemperatureSampler]::new((Join-Path $PSScriptRoot 'sensors'))
$script:temperatures=$null
Add-Type -Path (Join-Path $PSScriptRoot 'OriginalArtwork.cs') -ReferencedAssemblies @('System.Drawing.dll','System.dll')
Add-Type -Path (Join-Path $PSScriptRoot 'CodexQuota.cs') -ReferencedAssemblies @('System.Web.Extensions.dll','System.dll','System.Core.dll')
$codexCommand=Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
$codexPath=if($codexCommand){$codexCommand.Source}else{''}
if(-not $codexPath){
    $extensionRoot=Join-Path $env:USERPROFILE '.vscode\extensions'
    $candidate=Get-ChildItem -Path (Join-Path $extensionRoot 'openai.chatgpt-*\bin\windows-x86_64\codex.exe') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if($candidate){$codexPath=$candidate.FullName}
}
$quotaReader=[CodexQuotaReader]::new($codexPath)
$script:quota=$null
$script:queryChatGPTBalance=[bool]$QueryChatGPTBalance
$script:lastQuotaLog=[DateTime]::MinValue
$quotaLabels=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'assets\zh-CN.json') | ConvertFrom-Json
if($QuotaOnly){[CodexQuotaReader]::Query($codexPath)|ConvertTo-Json;exit}
. (Join-Path $PSScriptRoot 'HardwareInfo.ps1')
$hardwareInfo=Get-HardwareInfo
. (Join-Path $PSScriptRoot 'CpuFrequency.ps1')
$cpuFrequencyProfile=Find-CpuFrequencyProfile $hardwareInfo.CpuName
$savedSettings=Join-Path $PSScriptRoot 'preferences.json'
if(-not $PSBoundParameters.ContainsKey('Mode') -and (Test-Path -LiteralPath $savedSettings)) {
    try{$saved=Get-Content -Raw -LiteralPath $savedSettings | ConvertFrom-Json;if($saved.Theme -in @('Monitor','Clock','DeepSeek','ChatGPT','BongoCat','Spectrum')){$Mode=$saved.Theme}}catch{}
}
if(Test-Path -LiteralPath $savedSettings){
    try{$saved=Get-Content -Raw -LiteralPath $savedSettings|ConvertFrom-Json;if($saved.BongoParallel -is [bool]){$script:bongoParallel=$saved.BongoParallel};if($saved.BongoZoned -is [bool]){$script:bongoZoned=$saved.BongoZoned};if($saved.BongoHubPriority -is [bool]){$script:bongoHubPriority=$saved.BongoHubPriority};if($saved.BongoReduceColor -is [bool]){$script:bongoReduceColor=$saved.BongoReduceColor};if($saved.BongoSmooth -is [bool]){$script:bongoSmooth=$saved.BongoSmooth};if($saved.BongoPath -and (Test-Path -LiteralPath $saved.BongoPath)){$bongoSource.ExecutablePath=[string]$saved.BongoPath};if($saved.Rotation -in @(0,90,180,270)){$script:rotation=[int]$saved.Rotation}}catch{}
}
function Save-Preferences { @{Theme=$script:Mode;Rotation=$script:rotation;BongoPath=$bongoSource.ExecutablePath;BongoSmooth=$script:bongoSmooth;BongoReduceColor=$script:bongoReduceColor;BongoHubPriority=$script:bongoHubPriority;BongoZoned=$script:bongoZoned;BongoParallel=$script:bongoParallel}|ConvertTo-Json|Set-Content -Encoding UTF8 -LiteralPath $savedSettings }
function New-DisplayImage([int]$Width,[int]$Height){
    $image=New-ClockImage $Width $Height
    if($script:rotation -eq 0){return $image}
    try{return [ScreenOrientation]::Apply($image,$script:rotation,($Mode -in @('DeepSeek','ChatGPT')))}finally{$image.Dispose()}
}
function Connect-Hub([string]$Sn) {
    $legacy=$Model
    $profiles=Join-Path $PSScriptRoot 'device-profiles.json'
    if($legacy -eq 'Auto' -and (Test-Path -LiteralPath $profiles)){
        $entries=Get-Content -Raw -LiteralPath $profiles | ConvertFrom-Json
        $record=$entries.PSObject.Properties | Where-Object {$_.Name -eq $Sn}
        if($record -and $record.Value -in @('V1PRO','V2')){$legacy=[string]$record.Value}
    }
    try{$usb.Connect($Sn,$Model,$legacy)}catch{
        if($_.Exception.Message -notlike '*Legacy firmware does not report model*' -or -not $form){throw}
        $picker=[Windows.Forms.Form]::new();$picker.Text='首次连接：确认设备型号';$picker.ClientSize=[Drawing.Size]::new(420,155);$picker.StartPosition='CenterParent';$picker.FormBorderStyle='FixedDialog';$picker.MaximizeBox=$false
        $note=[Windows.Forms.Label]::new();$note.Text='旧固件无法自动报告型号。请按实际购买型号选择：';$note.SetBounds(15,15,390,40)
        $models=[Windows.Forms.ComboBox]::new();$models.DropDownStyle='DropDownList';$models.SetBounds(15,60,390,25);$models.Items.AddRange([string[]]@('V1PRO / V1P（320 × 170）','V2（320 × 240）'));$models.SelectedIndex=-1
        $confirm=[Windows.Forms.Button]::new();$confirm.Text='确认型号';$confirm.SetBounds(290,105,115,30);$confirm.Enabled=$false;$confirm.DialogResult='OK';$models.Add_SelectedIndexChanged({$confirm.Enabled=($models.SelectedIndex -ge 0)})
        $picker.Controls.AddRange(@($note,$models,$confirm))
        try{if($picker.ShowDialog($form) -ne 'OK'){throw '设备型号未确认，已取消连接。'};$legacy=@('V1PRO','V2')[$models.SelectedIndex]}finally{$picker.Dispose()}
        $usb.Connect($Sn,$Model,$legacy)
        $records=@{};if(Test-Path -LiteralPath $profiles){try{$old=Get-Content -Raw -LiteralPath $profiles|ConvertFrom-Json;foreach($entry in $old.PSObject.Properties){$records[$entry.Name]=$entry.Value}}catch{}}
        $records[$Sn]=$legacy;$records|ConvertTo-Json|Set-Content -LiteralPath $profiles -Encoding UTF8
    }
}
$sampler = [PcSampler]::new()
$script:snapshot = $null
$script:nextVoltageQuery=0.0
$accent=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#F4D35E'))
$ink=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#ECEFF1'))
$muted=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#97A1AA'))
$panel=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#1C2228'))
$line=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#333C44'))
$animationTime=[Diagnostics.Stopwatch]::StartNew()
function Reset-Animation {
    $script:lastBongoExact=0.0;$script:bongoExactTop=0;$script:nextBongoExact=0.0; $script:spectrumRenderer=[TacticalSpectrum]::new()
    $script:snapshot=$null; $script:lastPixels=$null; $script:nextSample=0.0
    $script:smoothCpu=0.0; $script:smoothRam=0.0; $script:smoothCpuTemp=0.0; $script:smoothGpuTemp=0.0; $script:smoothFrequency=0.0; $script:smoothGpuLoad=0.0; $script:lastAnimation=0.0
    $script:displayUpdates=0; $script:displayWatch=[Diagnostics.Stopwatch]::StartNew()
}
Reset-Animation
$vendorFolder = ([char]0x4F73).ToString() + [char]0x70B9 + 'V1PRO'
$dll = Join-Path (Join-Path (Split-Path $PSScriptRoot) $vendorFolder) 'libusb_package\libusb-1.0.dll'
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'native\libusb-1.0.dll')){$dll=Join-Path $PSScriptRoot 'native\libusb-1.0.dll'}
# Resolve the bundled library without changing the installed application or driver.
if (-not $SelfTest -and -not $SampleOnly) {
    if (-not (Test-Path -LiteralPath $dll)) { throw "USB library missing: $dll" }
    if ([HubUsb]::LoadLibrary($dll) -eq [IntPtr]::Zero) { throw 'Cannot load libusb. Run 64-bit Windows PowerShell.' }
}
function Get-ClockProgress([double]$Seconds) {
    # Fill before rollover, then ease back over the first 450 ms of the new minute.
    if($Seconds -lt 0.45){
        $t=$Seconds/0.45
        $ease=$t*$t*(3-2*$t)
        return 1-$ease*(1-$Seconds/59.85)
    }
    return [Math]::Min(1.0,$Seconds/59.85)
}
function New-ClockImage([int]$Width, [int]$Height) {
    if ($Mode -eq 'BongoCat') {
        if($SelfTest){return [Drawing.Bitmap]::new($Width,$Height)}
        $bongoSource.HubPriority=($script:bongoHubPriority -and ($script:running -or $RunSeconds -gt 0))
        if($script:bongoParallel -and ($script:running -or $RunSeconds -gt 0)){
            $bongoPipeline.Start($bongoSource,$Width,$Height)
            $latest=$bongoPipeline.Latest();if($latest){return $latest};return [Drawing.Bitmap]::new($Width,$Height)
        }else{$bongoPipeline.Stop()}
        return $bongoSource.Frame($Width,$Height)
    }
    if ($Mode -eq 'Spectrum') {
        if(-not $SelfTest -and ($script:running -or $RunSeconds -gt 0)){$audioSpectrum.Start()}
        $bands=if($SelfTest){[double[]](0..23|ForEach-Object{.15+.7*[Math]::Abs([Math]::Sin($_*.48))})}else{$audioSpectrum.Snapshot()}
        return $spectrumRenderer.Render($Width,$Height,$bands,$(if($SelfTest){'LIVE'}else{$audioSpectrum.Status}),[DateTime]::Now)
    }
    if ($Mode -eq 'Monitor') { return New-MonitorImage $Width $Height }
    if ($Mode -in @('DeepSeek','ChatGPT')) { return New-DeepSeekImage $Width $Height }
    $image = [Drawing.Bitmap]::new($Width, $Height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($image)
    $large = [Drawing.Font]::new('Consolas', [single]($Width / 5.8), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $small = [Drawing.Font]::new('Segoe UI', [single]($Height / 9), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $format = [Drawing.StringFormat]::new()
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(13,17,21))
        $now = Get-Date
        # Fractional edge coverage avoids visible one-pixel steps on the small display.
        $seconds=$now.Second+$now.Millisecond/1000.0
        $exactWidth=($Width-24)*(Get-ClockProgress $seconds)
        $progressWidth=[int][Math]::Floor($exactWidth)
        if($progressWidth -gt 0){$graphics.FillRectangle($accent,12,12,$progressWidth,4)}
        $coverage=$exactWidth-$progressWidth
        if($coverage -gt 0 -and $progressWidth -lt ($Width-24)){
            $edge=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb([int][Math]::Round(255*$coverage),$accent.Color))
            try{$graphics.FillRectangle($edge,(12+$progressWidth),12,1,4)}finally{$edge.Dispose()}
        }
        $graphics.FillRectangle($line,12,($Height-17),($Width-64),1)
        $graphics.FillPolygon($accent,[Drawing.Point[]]@([Drawing.Point]::new($Width-40,$Height-25),[Drawing.Point]::new($Width-12,$Height-25),[Drawing.Point]::new($Width-12,$Height-12),[Drawing.Point]::new($Width-48,$Height-12)))
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.DrawString($now.ToString('HH:mm:ss'), $large, $accent,
            [Drawing.RectangleF]::new(0, [single]($Height * 0.17), $Width, [single]($Height * 0.48)), $format)
        $graphics.DrawString($now.ToString('yyyy-MM-dd  ddd'), $small, $muted,
            [Drawing.RectangleF]::new(0, [single]($Height * 0.66), $Width, [single]($Height * 0.22)), $format)
    } finally { $format.Dispose(); $large.Dispose(); $small.Dispose(); $graphics.Dispose() }
    return $image
}
function New-DeepSeekImage([int]$Width,[int]$Height) {
    if($Mode -eq 'ChatGPT'){return New-ChatGPTImage $Width $Height}
    $asset=Join-Path $PSScriptRoot 'assets\deepseek-clock.png'
    if(-not $script:deepseekBackground){$script:deepseekBackground=[Drawing.Image]::FromFile($asset)}
    $background=$script:deepseekBackground
    $image=[Drawing.Bitmap]::new($Width,$Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g=[Drawing.Graphics]::FromImage($image)
    $font=[Drawing.Font]::new('Consolas',[single]($Width/9.8),[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    $brush=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#202B59'))
    $format=[Drawing.StringFormat]::new();$format.Alignment='Center';$format.LineAlignment='Center'
    try{
        $g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($background,0,0,$Width,$Height)
        $g.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $clockTop=$Height*.24
        $g.DrawString((Get-Date -Format 'HH:mm:ss'),$font,$brush,[Drawing.RectangleF]::new([single]($Width*.08),[single]$clockTop,[single]($Width*.62),[single]($Height*.35)),$format)
    }finally{$g.Dispose();$font.Dispose();$brush.Dispose();$format.Dispose()}
    return $image
}
function New-ChatGPTImage([int]$Width,[int]$Height) {
    if(-not $script:chatgptOriginal){$script:chatgptOriginal=[Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'assets\chatgpt-source.jfif'))}
    if(-not $script:chatgptDisplay){$script:chatgptDisplay=[OriginalArtwork]::RemoveExteriorBackground($script:chatgptOriginal)}
    if(-not $SelfTest -and $script:queryChatGPTBalance){$script:quota=$quotaReader.Poll()}
    $q=$script:quota
    $showBalance=[CodexQuotaReader]::CanDisplay($script:queryChatGPTBalance,$q)
    $plan=if($q -and $q.Success -and $q.Plan){$q.Plan.ToUpperInvariant()}else{'--'}
    $primary=$quotaLabels.Waiting;$secondary=$quotaLabels.WeekUnknown
    if($q -and $q.Success){
        if($q.Primary -match '^(\d+)([mhd]) left (\d+)%$'){
            $unit=switch($Matches[2]){'m'{$quotaLabels.Minute}'h'{$quotaLabels.Hour}'d'{$quotaLabels.Day}}
            $primary=$quotaLabels.ShortRemaining -f ($Matches[1]+$unit),$Matches[3]
        }else{$primary=$quotaLabels.QuotaUnknown}
        if($q.Secondary -match '^(\d+)([mhd]) left (\d+)%$'){
            if($Matches[1] -eq '7' -and $Matches[2] -eq 'd'){$secondary=$quotaLabels.WeekRemaining -f $Matches[3]}
            else{$unit=switch($Matches[2]){'m'{$quotaLabels.Minute}'h'{$quotaLabels.Hour}'d'{$quotaLabels.Day}};$secondary=$quotaLabels.ShortRemaining -f ($Matches[1]+$unit),$Matches[3]}
        }
        if($q.Status -eq 'Cached'){$secondary+=$quotaLabels.Cached}
    }elseif($q){$label=$quotaLabels.PSObject.Properties|Where-Object {$_.Name -eq $q.Status};if($label){$primary=$label.Value}}
    $image=[Drawing.Bitmap]::new($Width,$Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g=[Drawing.Graphics]::FromImage($image)
    $timeFont=[Drawing.Font]::new('Consolas',[single]($Width/9.8),[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    $small=[Drawing.Font]::new('Microsoft YaHei UI',[single]($Width/26),[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $pen=[Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#B7A4D0'),2)
    $textBrush=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#302B40'))
    $format=[Drawing.StringFormat]::new();$format.Alignment='Center';$format.LineAlignment='Center';$format.FormatFlags='NoWrap'
    try{
        $g.Clear([Drawing.Color]::White)
        $g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $sx=$Width/320.0;$sy=$Height/170.0
        $bubble=[Drawing.RectangleF]::new([single](4*$sx),[single](6*$sy),[single](205*$sx),[single](143*$sy))
        $g.FillEllipse([Drawing.Brushes]::White,$bubble);$g.DrawEllipse($pen,$bubble)
        # Show the entire original illustration, including the book text; no crop or redraw.
        $source=$script:chatgptDisplay
        $characterWidth=[single](144*$sx);$characterHeight=[single]($characterWidth*$source.Height/$source.Width)
        $destination=[Drawing.RectangleF]::new(($Width-$characterWidth-4*$sx),($Height-$characterHeight-5*$sy),$characterWidth,$characterHeight)
        $g.DrawImage($source,$destination,[Drawing.RectangleF]::new(0,0,$source.Width,$source.Height),[Drawing.GraphicsUnit]::Pixel)
        $clock=Get-Date -Format 'HH:mm:ss'
        $clockY=if($showBalance){29}else{53}
        $g.DrawString($clock,$timeFont,$textBrush,[Drawing.RectangleF]::new([single](13*$sx),[single]($clockY*$sy),[single](184*$sx),[single](43*$sy)),$format)
        if($showBalance){
            $lines=@()
            if($q.Primary){$lines+=($primary+$(if($q.Plan){' ('+$plan+')'}else{''}))}
            if($q.Secondary){$lines+=$secondary}
            for($line=0;$line -lt $lines.Count;$line++){
                $g.DrawString($lines[$line],$small,$textBrush,[Drawing.RectangleF]::new([single](12*$sx),[single]((83+$line*26)*$sy),[single](186*$sx),[single](22*$sy)),$format)
            }
        }
    }finally{$g.Dispose();$timeFont.Dispose();$small.Dispose();$pen.Dispose();$textBrush.Dispose();$format.Dispose()}
    return $image
}
function Format-ChineseQuota([string]$Value,[string]$Label) {
    if($Value -match '^(\d+)([mhd]) left (\d+)%$'){
        $unit=switch($Matches[2]){'m'{$quotaLabels.Minute}'h'{$quotaLabels.Hour}'d'{$quotaLabels.Day}}
        return $quotaLabels.Remaining -f $Label,$Matches[3],($Matches[1]+$unit)
    }
    return $quotaLabels.UnknownRemaining -f $Label
}
$script:hardwareTextLayouts=@{}
function Format-CompactHardware([string]$Value){
    return (($Value -replace '\(R\)|\(TM\)','' -replace '\b(Core|Radeon|GeForce|Processor|Graphics)\b','' -replace '\s+\d+\s+Cores\s*/\s*\d+\s+Threads','' -replace '\s+',' ').Trim())
}
function Draw-HardwareLine($Graphics,[string]$Label,[string]$Value,[single]$Y,[single]$RowHeight=23,[single]$MaxSize=14,[switch]$SingleLine,[single]$ValueWidth=262) {
    $labelFont=[Drawing.Font]::new('Consolas',11,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    $format=[Drawing.StringFormat]::new()
    $format.LineAlignment=[Drawing.StringAlignment]::Center
    $format.Trimming=[Drawing.StringTrimming]::EllipsisCharacter
    $valueFont=$null
    try {
        $key="$RowHeight|$MaxSize|$SingleLine|$ValueWidth|$Value"
        $layout=$script:hardwareTextLayouts[$key]
        if(-not $layout){
            $size=[double]$MaxSize;$wrap=$false
            while($true){
                if($valueFont){$valueFont.Dispose()}
                $valueFont=[Drawing.Font]::new('Tahoma',[single]$size,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
                if(-not $wrap){
                    if($Graphics.MeasureString($Value,$valueFont).Width -le $ValueWidth){break}
                    if($SingleLine){if($size -le 9){break};$size-=1;continue}
                    if($size -gt 11){$size--;continue}
                    $wrap=$true
                }
                $chars=0;$lines=0
                $null=$Graphics.MeasureString($Value,$valueFont,[Drawing.SizeF]::new($ValueWidth,($RowHeight-2)),$format,[ref]$chars,[ref]$lines)
                if(($chars -ge $Value.Length -and $lines -le 2) -or $size -le 9){break}
                $size-=1
            }
            $layout=@{Size=$size;Wrap=$wrap};$script:hardwareTextLayouts[$key]=$layout
        }
        if($valueFont){$valueFont.Dispose()}
        $valueFont=[Drawing.Font]::new('Tahoma',[single]$layout.Size,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
        if(-not $layout.Wrap){$format.FormatFlags=[Drawing.StringFormatFlags]::NoWrap}
        if(-not $SingleLine){$Graphics.FillRectangle($line,10,($Y+$RowHeight-2),300,1)}
        $Graphics.DrawString($Label,$labelFont,$accent,10,($Y+$(if($SingleLine){0}else{2})))
        $Graphics.DrawString($Value,$valueFont,$ink,[Drawing.RectangleF]::new(48,$Y,$ValueWidth,($RowHeight-$(if($SingleLine){0}else{2}))),$format)
    }finally{if($valueFont){$valueFont.Dispose()};$labelFont.Dispose();$format.Dispose()}
}
function New-MonitorImage([int]$Width,[int]$Height) {
    if(-not $SelfTest){$script:temperatures=$temperatureReader.Poll();$script:loads=$loadReader.Poll()}
    $nowMs=$animationTime.Elapsed.TotalMilliseconds
    if ($null -eq $script:snapshot -or $nowMs -ge $script:nextSample) {
        $script:snapshot = $sampler.Sample()
        $script:nextSample=$nowMs+500
    }
    $s = $script:snapshot
    $dt=[Math]::Max(0,$nowMs-$script:lastAnimation)
    $alpha=1-[Math]::Exp(-$dt/220.0)
    if ($null -ne $s.CpuPercent) { $script:smoothCpu += ($s.CpuPercent-$script:smoothCpu)*$alpha }
    if ($null -ne $s.MemoryPercent) { $script:smoothRam += ($s.MemoryPercent-$script:smoothRam)*$alpha }
    $script:lastAnimation=$nowMs
    $image = [Drawing.Bitmap]::new($Width,$Height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($image)
    $scale = $Height / 170.0
    $timeFont = [Drawing.Font]::new('Consolas',25,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
    $font = [Drawing.Font]::new('Consolas',18,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $ramFont = [Drawing.Font]::new('Consolas',16,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $small = [Drawing.Font]::new('Tahoma',10,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
    $track = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(53,62,70))
    try {
        $g.Clear([Drawing.Color]::FromArgb(13,17,21))
        $g.FillRectangle([Drawing.Brushes]::WhiteSmoke,0,0,$Width,36)
        $g.FillPolygon($accent,[Drawing.Point[]]@([Drawing.Point]::new(246,0),[Drawing.Point]::new(320,0),[Drawing.Point]::new(320,36),[Drawing.Point]::new(230,36)))
        $g.FillRectangle($line,0,36,$Width,1)
        $g.FillRectangle($panel,4,[single](40*$scale),152,[single](35*$scale))
        $g.FillRectangle($panel,166,[single](40*$scale),150,[single](35*$scale))
        $g.FillRectangle($accent,4,[single](40*$scale),2,16)
        $g.FillRectangle($accent,166,[single](40*$scale),2,16)
        $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
        $g.DrawString((Get-Date -Format 'HH:mm:ss'),$timeFont,[Drawing.Brushes]::Black,10,3)
        $g.DrawString((Get-Date -Format 'MM-dd'),$font,[Drawing.Brushes]::Black,250,10)
        $cpu = if ($null -eq $s.CpuPercent) { 'CPU --' } else { 'CPU {0:F0}%' -f $s.CpuPercent }
        $ram = if ($null -eq $s.MemoryPercent) { 'RAM --' } else { 'RAM {0:F0}%' -f $s.MemoryPercent }
        $g.DrawString($cpu,$ramFont,$ink,10,[single](44*$scale))
        $cpuTemperature=if($null -ne $script:temperatures.Cpu){'({0:F0}' -f $script:temperatures.Cpu}else{'(--'}
        $cpuTemperature+=[char]0xB0+'C)'
        $cpuTempFont=[Drawing.Font]::new('Tahoma',11,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
        $detailFormat=[Drawing.StringFormat]::new();$detailFormat.Alignment=[Drawing.StringAlignment]::Far;$detailFormat.FormatFlags=[Drawing.StringFormatFlags]::NoWrap
        try{$g.DrawString($cpuTemperature,$cpuTempFont,$ink,[Drawing.RectangleF]::new(92,[single](48*$scale),56,18),$detailFormat)}finally{$cpuTempFont.Dispose();$detailFormat.Dispose()}
        $g.DrawString($ram,$ramFont,$ink,172,[single](45*$scale))
        if($null -ne $s.MemoryPercent){
            $memory='({0:F1}/{1:0.#}G)' -f $s.UsedMemoryGiB,$s.TotalMemoryGiB
            while($g.MeasureString($memory,$small).Width -gt 56 -and $small.Size -gt 9){
                $size=$small.Size-1;$small.Dispose();$small=[Drawing.Font]::new('Tahoma',[single]$size,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
            }
            $detailFormat=[Drawing.StringFormat]::new();$detailFormat.Alignment=[Drawing.StringAlignment]::Far;$detailFormat.FormatFlags=[Drawing.StringFormatFlags]::NoWrap
            try{$g.DrawString($memory,$small,$muted,[Drawing.RectangleF]::new(254,[single](49*$scale),56,18),$detailFormat)}finally{$detailFormat.Dispose()}
        }
        $g.FillRectangle($track,10,[single](65*$scale),138,[single](7*$scale))
        $g.FillRectangle($track,172,[single](65*$scale),138,[single](7*$scale))
        if ($null -ne $s.CpuPercent) { $g.FillRectangle($accent,10,[single](65*$scale),[single](138*$script:smoothCpu/100),[single](7*$scale)) }
        if ($null -ne $s.MemoryPercent) { $g.FillRectangle($accent,172,[single](65*$scale),[single](138*$script:smoothRam/100),[single](7*$scale)) }
        $frequencyPercent=$null
        if($cpuFrequencyProfile){$frequencyPercent=[PcLoadReader]::FrequencyRangePercent($script:loads.CpuGhz,$cpuFrequencyProfile.BaseGhz,$cpuFrequencyProfile.MaxTurboGhz)}
        $frequencyText=if($null -ne $frequencyPercent){'CPU {0:F0}%' -f $frequencyPercent}else{'CPU --%'}
        $frequencyDetail=if($null -ne $script:loads.CpuGhz){'({0:F2}GHz)' -f $script:loads.CpuGhz}else{'(--GHz)'}
        $gpuText=if($null -ne $script:loads.GpuPercent){'GPU {0:F0}%' -f $script:loads.GpuPercent}else{'GPU --%'}
        $gpuDetail=if($null -ne $script:temperatures.Gpu){'({0:F0}' -f $script:temperatures.Gpu}else{'(--'}
        $gpuDetail+=[char]0xB0+'C)'
        foreach($loadItem in @(@($frequencyText,$frequencyPercent,10,'smoothFrequency',$frequencyDetail),@($gpuText,$script:loads.GpuPercent,172,'smoothGpuLoad',$gpuDetail))){
            $text=$loadItem[0];$value=$loadItem[1];$x=[int]$loadItem[2];$variable=$loadItem[3];$detail=[string]$loadItem[4]
            $g.FillRectangle($panel,($x-6),[single](78*$scale),150,[single](34*$scale))
            $g.FillRectangle($accent,($x-6),[single](78*$scale),2,16)
            if($null -ne $value){
                $smoothed=(Get-Variable -Scope Script -Name $variable -ValueOnly)
                $smoothed+=([Math]::Max(0.0,[Math]::Min(100.0,[double]$value))-$smoothed)*$alpha
                Set-Variable -Scope Script -Name $variable -Value $smoothed
            }
            $g.DrawString($text,$ramFont,$ink,$x,[single](79*$scale))
            $detailFont=[Drawing.Font]::new('Tahoma',10,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
            $detailFormat=[Drawing.StringFormat]::new();$detailFormat.Alignment=[Drawing.StringAlignment]::Far;$detailFormat.FormatFlags=[Drawing.StringFormatFlags]::NoWrap
            try{
                if($g.MeasureString($detail,$detailFont).Width -gt 56){$detailFont.Dispose();$detailFont=[Drawing.Font]::new('Tahoma',9,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)}
                $g.DrawString($detail,$detailFont,$ink,[Drawing.RectangleF]::new(($x+82),[single](83*$scale),56,18),$detailFormat)
            }finally{$detailFont.Dispose();$detailFormat.Dispose()}
            $g.FillRectangle($track,$x,[single](102*$scale),138,[single](7*$scale))
            if($null -ne $value){$g.FillRectangle($accent,$x,[single](102*$scale),[single](138*$smoothed/100.0),[single](7*$scale))}
        }
        Draw-HardwareLine $g 'CPU' (Format-CompactHardware $hardwareInfo.CpuDisplay) ([single](123*$scale)) ([single](13*$scale)) 11 -SingleLine -ValueWidth 146
        Draw-HardwareLine $g 'RAM' ($hardwareInfo.MemoryDisplay -replace 'GiB','G' -replace ' MHz','MHz') ([single](136*$scale)) ([single](13*$scale)) 11 -SingleLine -ValueWidth 146
        Draw-HardwareLine $g 'GPU' (Format-CompactHardware $hardwareInfo.GpuName) ([single](149*$scale)) ([single](13*$scale)) 11 -SingleLine -ValueWidth 146
        $voltage='-- V'
        if($usb -and $null -ne $usb.VoltageMillivolts -and ([DateTime]::UtcNow-$usb.VoltageUpdatedUtc).TotalSeconds -lt 6){$voltage='{0:F3} V' -f ($usb.VoltageMillivolts/1000.0)}
        $voltageFont=[Drawing.Font]::new('Consolas',23,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
        try{
            $g.FillRectangle($panel,200,[single](115*$scale),112,[single](48*$scale))
            $g.DrawString('USB IN',$small,$muted,207,[single](118*$scale))
            $g.DrawString($voltage,$voltageFont,$accent,204,[single](134*$scale))
        }finally{$voltageFont.Dispose()}
    } finally { $g.Dispose(); $timeFont.Dispose(); $font.Dispose(); $ramFont.Dispose(); $small.Dispose(); $track.Dispose() }
    return $image
}
function Convert-ClockImage([Drawing.Bitmap]$Image) {
    $rect = [Drawing.Rectangle]::new(0, 0, $Image.Width, $Image.Height)
    $bits = $Image.LockBits($rect, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $bytes = [byte[]]::new($bits.Stride * $Image.Height)
        [Runtime.InteropServices.Marshal]::Copy($bits.Scan0, $bytes, 0, $bytes.Length)
        return ,([HubUsb]::BgraToRgb565($bytes, $Image.Width, $Image.Height, $bits.Stride))
    } finally { $Image.UnlockBits($bits) }
}
function Send-DisplayImage([Drawing.Bitmap]$Image) {
    $pixels=Convert-ClockImage $Image
    if($Mode -eq 'BongoCat'){
        if($script:bongoSmooth -and $script:bongoReduceColor){$pixels=[HubUsb]::QuantizeRgb565($pixels,4,4,4)}
        if($script:bongoSmooth -and $script:bongoZoned){
            $now=$animationTime.Elapsed.TotalMilliseconds;$rows=0
            if($now -ge $script:nextBongoExact){$rows=[Math]::Min(8,$usb.Height-$script:bongoExactTop)}
            $script:lastPixels=$usb.SendAnimationZoned($pixels,$script:lastPixels,$script:bongoReduceColor,$script:rotation,$script:bongoExactTop,$rows)
            if($rows -gt 0){$script:bongoExactTop=($script:bongoExactTop+$rows)%$usb.Height;$script:nextBongoExact=$animationTime.Elapsed.TotalMilliseconds+100}
        }else{
            $threshold=0
            if($script:bongoSmooth -and $animationTime.Elapsed.TotalMilliseconds-$script:lastBongoExact -lt 2000){$threshold=if($script:bongoReduceColor){32}else{16}}else{$script:lastBongoExact=$animationTime.Elapsed.TotalMilliseconds}
            $script:lastPixels=$usb.SendAnimationFiltered($pixels,$script:lastPixels,$threshold)
        }
    }else{
        if($Mode -eq 'Spectrum'){$script:lastPixels=$usb.SendSpectrum($pixels,$script:lastPixels)}elseif($Mode -in @('Monitor','Clock')){$usb.SendDirty($pixels,$script:lastPixels)}else{$usb.SendFrame($pixels)}
        if($Mode -ne 'Spectrum'){$script:lastPixels=$pixels}
    }
    $script:displayUpdates++
}
function Update-Voltage {
    if($Mode -ne 'Monitor' -or $animationTime.Elapsed.TotalMilliseconds -lt $script:nextVoltageQuery){return}
    $value=$usb.QueryVoltage()
    $script:nextVoltageQuery=$animationTime.Elapsed.TotalMilliseconds+$(if($null -eq $value){10000}else{2000})
}
if ($SelfTest) {
    $cpuFrequencyProfile=Find-CpuFrequencyProfile 'Intel(R) Core(TM) i7-4790 CPU @ 3.60GHz'
    if(-not $cpuFrequencyProfile -or [PcLoadReader]::FrequencyRangePercent(3.8,3.6,4.0) -lt 49.99 -or [PcLoadReader]::FrequencyRangePercent(3.8,3.6,4.0) -gt 50.01){throw 'CPU model or midpoint mapping failed'}
    if([PcLoadReader]::FrequencyRangePercent(1.0,3.6,4.0) -ne 0 -or [PcLoadReader]::FrequencyRangePercent(4.2,3.6,4.0) -ne 100 -or $null -ne [PcLoadReader]::FrequencyRangePercent(3.8,4.0,4.0)){throw 'CPU range clamping/invalid handling failed'}
    if((Find-CpuFrequencyProfile 'Intel Core i7-4790K').BaseGhz -ne 4.0 -or $null -ne (Find-CpuFrequencyProfile 'Intel Core i5-12400') -or (Find-CpuFrequencyProfile 'AMD Ryzen 7 7800X3D 8-Core Processor').BaseGhz -ne 4.2){throw 'CPU exact model matching failed'}
    $engineNames=[string[]]@('pid_1_luid_0_phys_0_eng_0_engtype_3D','pid_2_luid_0_phys_0_eng_0_engtype_3D','pid_1_luid_0_phys_0_eng_1_engtype_Copy','pid_1_luid_1_phys_0_eng_0_engtype_3D')
    if([PcLoadReader]::BusiestEngine($engineNames,[double[]]@(20,30,40,10)) -ne 50){throw 'GPU must sum processes per engine, then select busiest engine'}
    if($null -ne [PcLoadReader]::BusiestEngine([string[]]@(),[double[]]@())){throw 'Missing GPU counters must not be reported as zero load'}
    $zonedOld=[byte[]]::new(80);$zonedNew=[byte[]]::new(80);$zonedNew[10]=40;$zonedNew[66]=40
    $z=[HubUsb]::FilterAnimationZoned($zonedNew,$zonedOld,4,10,$true,0,0,0)
    if($z[10] -ne 0 -or $z[66] -ne 40){throw 'Zoned precision must preserve lower-region detail'}
    $z=[HubUsb]::FilterAnimationZoned($zonedNew,$zonedOld,4,10,$true,180,0,0)
    if($z[10] -ne 40 -or $z[66] -ne 0){throw 'Zoned priority must follow device rotation'}
    $z=[HubUsb]::FilterAnimationZoned($zonedNew,$zonedOld,4,10,$true,0,1,1)
    if($z[10] -ne 40){throw 'Batched exact reconciliation must retain all changes in its strip'}
    if([HubUsb]::AnimationLogicalY(0,5,4,10,90) -lt 0.6 -or [HubUsb]::AnimationLogicalY(3,5,4,10,270) -lt 0.6){throw 'Portrait priority mapping failed'}
    $colors=[byte[]]@(0,0,248,0,7,224,0,31,255,255,123,239)
    $reduced=[HubUsb]::QuantizeRgb565($colors,4,4,4)
    if($reduced[0] -ne 0 -or $reduced[8] -ne 255 -or $reduced[9] -ne 255 -or [BitConverter]::ToString([HubUsb]::QuantizeRgb565($reduced,4,4,4)) -ne [BitConverter]::ToString($reduced)){throw 'Color quantization endpoints or stability failed'}
    if([BitConverter]::ToString([HubUsb]::QuantizeRgb565($colors,5,6,5)) -ne [BitConverter]::ToString($colors)){throw 'Full precision quantization must preserve pixels'}
    $sentPixel=[byte[]]@(0,0)
    foreach($red in @(8,16)){
        $smallChange=[HubUsb]::FilterAnimation([byte[]]@($red,0),$sentPixel,16)
        if($smallChange[0] -ne 0){throw 'Small pixel change should be suppressed'}
    }
    if(([HubUsb]::FilterAnimation([byte[]]@(24,0),$sentPixel,16))[0] -ne 24){throw 'Accumulated changes must be compared to sent pixels'}
    if(([HubUsb]::FilterAnimation([byte[]]@(8,0),$sentPixel,0))[0] -ne 8 -or $sentPixel[0] -ne 0){throw 'Exact reconciliation or filter cache ownership failed'}
    $legacyJed='JED,684018,128,16,15,154'
    if(-not [HubUsb]::ConfirmLegacyApplication($legacyJed,'FW,1,err,busy',$true) -or [HubUsb]::ConfirmLegacyApplication($legacyJed,'FW,1,err,busy',$false) -or [HubUsb]::ConfirmLegacyApplication($legacyJed,'FW,1,info,0,0,boot,0',$true) -or [HubUsb]::ConfirmLegacyApplication('JED,bad','FW,1,err,busy',$true)){throw 'Legacy busy firmware validation failed'}
    $oldAnimation=[byte[]]::new(33*19*2);$newAnimation=[byte[]]::new($oldAnimation.Length)
    foreach($point in @(0,32,330,626)){$newAnimation[$point*2]=248}
    $rebuilt=[byte[]]$oldAnimation.Clone()
    foreach($r in [HubUsb]::AnimationRegions($newAnimation,$oldAnimation,33,19)){
        if($r[0] -lt 0 -or $r[1] -lt 0 -or $r[0]+$r[2] -gt 33 -or $r[1]+$r[3] -gt 19){throw 'Animation region out of bounds'}
        for($y=$r[1];$y -lt $r[1]+$r[3];$y++){[Array]::Copy($newAnimation,($y*33+$r[0])*2,$rebuilt,($y*33+$r[0])*2,$r[2]*2)}
    }
    if([BitConverter]::ToString($rebuilt) -ne [BitConverter]::ToString($newAnimation) -or [HubUsb]::AnimationRegions($newAnimation,$newAnimation,33,19).Length -ne 0){throw 'Animation regions must cover every changed pixel and skip identical frames'}
    $square=[Drawing.Bitmap]::new(8,8)
    $sg=[Drawing.Graphics]::FromImage($square);$sg.Clear([Drawing.Color]::Lime);$sg.Dispose()
    foreach($height in @(170,240)){
        $stretched=[BongoSource]::Stretch($square,320,$height)
        try{if($stretched.Width -ne 320 -or $stretched.Height -ne $height -or $stretched.GetPixel(160,[int]($height/2)).G -ne 255){throw 'BongoCat stretch rendering failed'}}finally{$stretched.Dispose()}
    }
    $square.Dispose()
    $marker=[Drawing.Bitmap]::new(4,2);$marker.SetPixel(0,0,[Drawing.Color]::Red)
    $flipped=[ScreenOrientation]::Apply($marker,0,$false,$true)
    try{
        if($flipped.GetPixel(3,0).R -ne 255){throw 'Horizontal mirror failed'}
        $restored=[ScreenOrientation]::Apply($flipped,0,$false,$true)
        try{if($restored.GetPixel(0,0).R -ne 255){throw 'Double mirror must restore orientation'}}finally{$restored.Dispose()}
    }finally{$flipped.Dispose()}
    $turned=[ScreenOrientation]::Apply($marker,180,$false)
    try{if($turned.GetPixel(3,1).R -ne 255){throw '180 degree rotation failed'}}finally{$turned.Dispose();$marker.Dispose()}
    if([TemperatureSampler]::Rank('Cpu','CPU Package') -ne 0 -or [TemperatureSampler]::Rank('Cpu','CPU Core #1 Distance to TjMax') -ne -1 -or [TemperatureSampler]::Rank('GpuAmd','GPU Hot Spot') -ne -1){throw 'Temperature sensor selection failed'}
    if([HubUsb]::ParseVoltage('PONG,5138') -ne 5138 -or $null -ne [HubUsb]::ParseVoltage('PONG,ok') -or $null -ne [HubUsb]::ParseVoltage('PONG,9999999999')){throw 'Voltage parser failed'}
    if((Get-ClockProgress 59.9) -ne 1 -or (Get-ClockProgress 0) -ne 1){throw 'Minute rollover must stay full'}
    if((Get-ClockProgress 0.225) -lt 0.49 -or (Get-ClockProgress 0.225) -gt 0.51){throw 'Minute rewind easing failed'}
    if([Math]::Abs((Get-ClockProgress 0.45)-(0.45/59.85)) -gt 0.000001){throw 'Minute rewind must join continuous progress'}
    $recovery=[HubReconnectState]::new();$now=[DateTime]::UtcNow
    $recovery.Start('A');$recovery.Failed($now)
    if($recovery.ShouldAttempt($now.AddSeconds(1),$false) -or -not $recovery.ShouldAttempt($now.AddSeconds(4),$false)){throw 'Reconnect backoff failed'}
    if($recovery.SelectTarget([string[]]@('B')) -or $recovery.SelectTarget([string[]]@('B','A')) -ne 'A'){throw 'Reconnect must retain selected SN'}
    $recovery.Stop();if($recovery.ShouldAttempt($now.AddHours(1),$false)){throw 'Manual stop must disable reconnect'}
    $recovery.Start('B');if($recovery.SelectTarget([string[]]@('A','B')) -ne 'B'){throw 'Explicit new target failed'}
    $artTest=[Drawing.Bitmap]::new(5,5);$artGraphics=[Drawing.Graphics]::FromImage($artTest)
    $artGraphics.Clear([Drawing.Color]::Black);$artGraphics.FillRectangle([Drawing.Brushes]::White,1,1,3,3);$artGraphics.Dispose();$artTest.SetPixel(2,2,[Drawing.Color]::Black)
    $cutout=[OriginalArtwork]::RemoveExteriorBackground($artTest)
    try{if($cutout.GetPixel(0,0).A -ne 0 -or $cutout.GetPixel(2,2).A -ne 255 -or $cutout.GetPixel(1,1).R -ne 255){throw 'Exterior removal changed enclosed artwork'}}finally{$cutout.Dispose();$artTest.Dispose()}
    $fixture='{"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":35,"windowDurationMins":300},"secondary":{"usedPercent":6,"windowDurationMins":10080}}}}'
    $parsed=[CodexQuotaReader]::Parse($fixture)
    if([CodexQuotaReader]::CanDisplay($false,$parsed)){throw 'Disabled balance must never display saved data'}
    if(-not [CodexQuotaReader]::CanDisplay($true,$parsed)){throw 'Fresh successful quota should display when enabled'}
    if([CodexQuotaReader]::CanDisplay($true,[CodexQuotaReader]::Parse('{"result":{}}'))){throw 'Missing quota must stay hidden'}
    $parsed.UpdatedUtc=[DateTime]::UtcNow.AddMinutes(-3)
    if([CodexQuotaReader]::CanDisplay($true,$parsed)){throw 'Expired quota must stay hidden'}
    $parsed.UpdatedUtc=[DateTime]::UtcNow
    if($parsed.Primary -ne '5h left 65%' -or $parsed.Secondary -ne '7d left 94%'){throw 'Quota remaining/window conversion failed'}
    if([CodexQuotaReader]::Parse('{"result":{}}').Success){throw 'Missing quota cannot be reported as a percentage'}
    $multiple='{"result":{"rateLimits":{"limitId":"codex_other","primary":{"usedPercent":1,"windowDurationMins":60}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":100,"windowDurationMins":300}}}}}'
    if([CodexQuotaReader]::Parse($multiple).Primary -ne '5h left 0%'){throw 'Codex bucket selection/exhausted quota failed'}
    if ([PcSampler]::CpuDelta(50,80,20) -ne 50) { throw 'CPU idle subtraction failed' }
    if ($null -ne [PcSampler]::CpuDelta(0,0,0)) { throw 'CPU zero interval must be unknown' }
    if ($null -ne $sampler.Sample().CpuPercent) { throw 'First CPU sample must be unknown' }
    Start-Sleep -Milliseconds 250
    $sample = $sampler.Sample()
    if ($null -eq $sample.CpuPercent -or $sample.CpuPercent -lt 0 -or $sample.CpuPercent -gt 100) { throw 'CPU sample failed' }
    if ($null -eq $sample.MemoryPercent -or $sample.TotalMemoryGiB -le 0) { throw 'Memory sample failed' }
    $rgb = [HubUsb]::BgraToRgb565([byte[]](0,0,255,255, 0,255,0,255, 255,0,0,255),3,1,12)
    if ([BitConverter]::ToString($rgb) -ne 'F8-00-07-E0-00-1F') { throw 'RGB565 color order failed' }
    $packet = [HubUsb]::BuildFrame($rgb,3,1)
    if ([BitConverter]::ToString($packet[0..7]) -ne 'A5-5A-0B-06-00-00-00-00') { throw 'LIVE header failed' }
    $region=[HubUsb]::BuildRegion([byte[]](248,0),320,170,10,65,1,1)
    if([BitConverter]::ToString($region) -ne 'A5-5A-0B-02-00-00-00-01-0A-00-41-00-01-00-01-00-F8-00'){throw 'Region encoding failed'}
    $before=[byte[]]::new(24);$after=[byte[]]::new(24);$after[14]=248
    $bounds=[HubUsb]::DirtyBounds($before,$after,4,3,0,3)
    if(($bounds -join ',') -ne '3,1,1,1'){throw 'Dirty rectangle bounds failed'}
    if($null -ne [HubUsb]::DirtyBounds($after,$after,4,3,0,3)){throw 'Unchanged frame should not transmit'}
    if([BitConverter]::ToString([HubUsb]::Crop($after,4,3,3,1,1,1)) -ne 'F8-00'){throw 'Region crop failed'}
    $rejected = $false
    try { $null = [HubUsb]::BuildFrame([byte[]](0),320,170) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid frame length was accepted' }
    $script:temperatures=[TemperatureSnapshot]::new();$script:temperatures.Cpu=48;$script:temperatures.Gpu=60;$script:loads=[PcLoadSnapshot]::new();$script:loads.CpuGhz=3.9;$script:loads.CpuFrequencyPercent=108;$script:loads.GpuPercent=42
    $savedMode=$Mode
    foreach ($testMode in @('Clock','Monitor','DeepSeek','ChatGPT','BongoCat','Spectrum')) {
    $Mode=$testMode
    foreach ($height in @(170,240)) {
        $image = New-ClockImage 320 $height
        try {
            $pixels = Convert-ClockImage $image
            if ($pixels.Length -ne 320*$height*2) { throw 'Rendered frame size failed' }
            foreach($angle in @(90,180,270)){
                $turned=[ScreenOrientation]::Apply($image,$angle,($testMode -in @('DeepSeek','ChatGPT')))
                try{if($turned.Width -ne 320 -or $turned.Height -ne $height){throw 'Rotation must preserve physical frame dimensions'}}finally{$turned.Dispose()}
            }
            $image.Save((Join-Path $PSScriptRoot "preview-$testMode-$height.png"))
        } finally { $image.Dispose() }
    }
    }
    $savedHardware=$hardwareInfo
    try{
        $hardwareInfo=[pscustomobject]@{
            CpuDisplay='Intel(R) Core(TM) Ultra 9 285K Processor 24 Cores / 24 Threads'
            MemoryDisplay='128 GiB DDR5 6400 MHz / 6000 MHz (4 x 32 GiB)'
            GpuName='NVIDIA GeForce RTX 4090 / AMD Radeon RX 7900 XTX Graphics'
        }
        $Mode='Monitor'
        foreach($height in @(170,240)){
            $image=New-ClockImage 320 $height
            try{$image.Save((Join-Path $PSScriptRoot "preview-Monitor-long-$height.png"))}finally{$image.Dispose()}
            foreach($value in @($hardwareInfo.CpuDisplay,$hardwareInfo.GpuName)){
                $value=Format-CompactHardware $value
                $key="$([single](13*$height/170.0))|11|True|146|$value"
                if(-not $script:hardwareTextLayouts.ContainsKey($key) -or $script:hardwareTextLayouts[$key].Wrap){throw 'Compact hardware text must stay on one line'}
            }
        }
    }finally{$hardwareInfo=$savedHardware}
    $Mode=$savedMode
    $sample | ConvertTo-Json
    Write-Output 'PASS: quota parsing, CPU/memory, RGB565, region operations, six themes and both panel sizes.'
    exit
}
if ($SampleOnly) {
    $null=$sampler.Sample(); Start-Sleep -Seconds 1
    [pscustomobject]@{Hardware=$hardwareInfo;Performance=$sampler.Sample()} | ConvertTo-Json -Depth 5
    exit
}
$usb = [HubUsb]::new()
if ($Probe -or $RunSeconds -gt 0 -or $Benchmark -ne 'None') {
    try {
        $devices = @($usb.ListDevices())
        if ($Probe) { $devices; $usb.Diagnostics; exit }
        if (-not $Serial) {
            if ($devices.Count -ne 1) { throw 'Specify -Serial with a complete device SN.' }
            $Serial = $devices[0]
        }
        Connect-Hub $Serial
        Write-Output $usb.Identity
        Write-Output $usb.Firmware
        if ($Benchmark -ne 'None') {
            $image=New-ClockImage $usb.Width $usb.Height
            try { $cached=Convert-ClockImage $image } finally { $image.Dispose() }
            $usb.SendFrame($cached)
            $samples=[Collections.Generic.List[double]]::new()
            $watch=[Diagnostics.Stopwatch]::StartNew()
            $duration=if($RunSeconds -gt 0){$RunSeconds}else{5}
            while($watch.Elapsed.TotalSeconds -lt $duration) {
                $one=[Diagnostics.Stopwatch]::StartNew()
                if($Benchmark -eq 'Full'){$usb.SendFrame($cached)}
                else {$usb.SendRegion([HubUsb]::Crop($cached,$usb.Width,$usb.Height,10,65,300,5),10,65,300,5)}
                $samples.Add($one.Elapsed.TotalMilliseconds)
            }
            $elapsed=$watch.Elapsed.TotalSeconds
            $ordered=@($samples | Sort-Object)
            $result=[ordered]@{Mode=$Benchmark;Frames=$samples.Count;Seconds=$elapsed;AcknowledgedFps=$samples.Count/$elapsed;MedianMs=$ordered[[int][Math]::Floor(($ordered.Count-1)*0.5)];P95Ms=$ordered[[int][Math]::Floor(($ordered.Count-1)*0.95)];PayloadBytesPerFrame=$(if($Benchmark -eq 'Full'){$cached.Length}else{300*5*2});Serial=$usb.Serial;Identity=$usb.Identity;Firmware=$usb.Firmware}
            $result | ConvertTo-Json | Tee-Object -FilePath (Join-Path $PSScriptRoot "benchmark-$Benchmark.json")
            exit
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Reset-Animation
        $null=[HubUsb]::timeBeginPeriod(1)
        while ($watch.Elapsed.TotalSeconds -lt $RunSeconds) {
            $tick=[Diagnostics.Stopwatch]::StartNew()
            Update-Voltage
            $image = New-DisplayImage $usb.Width $usb.Height
            try { Send-DisplayImage $image } finally { $image.Dispose() }
            $delay=if($Mode -in @('Monitor','Clock','BongoCat','Spectrum')){[Math]::Max(1,[Math]::Ceiling(1000/$(if($Mode -in @('Clock','Spectrum')){120.0}elseif($Mode -eq 'BongoCat'){$(if($script:bongoParallel){60.0}else{30.0})}else{60.0})-$tick.Elapsed.TotalMilliseconds))}else{1000}
            Start-Sleep -Milliseconds $delay
        }
        [ordered]@{Mode=$Mode;Seconds=$watch.Elapsed.TotalSeconds;RenderUpdates=$script:displayUpdates;RenderFps=$script:displayUpdates/$watch.Elapsed.TotalSeconds;AckPackets=$usb.Frames;RegionPackets=$usb.RegionFrames;PixelBytes=$usb.PixelBytes;LastReply=$usb.LastReply} | ConvertTo-Json | Tee-Object -FilePath (Join-Path $PSScriptRoot 'animation-test.json')
    } finally { $audioSpectrum.Dispose();$bongoPipeline.Dispose();$bongoSource.Dispose();$loadReader.Dispose();$temperatureReader.Dispose();$quotaReader.Dispose();$null=[HubUsb]::timeEndPeriod(1); $usb.Dispose() }
    exit
}
[Windows.Forms.Application]::EnableVisualStyles()
$instanceName='Local\HubPcMonitor.'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$instanceMutex=[Threading.Mutex]::new($false,$instanceName)
$hasInstance=$false
try{$hasInstance=$instanceMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$hasInstance=$true}
$showSignal=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,($instanceName+'.Show'))
$exitSignal=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,($instanceName+'.Exit'))
if(-not $hasInstance){$null=$showSignal.Set();$showSignal.Dispose();$exitSignal.Dispose();$instanceMutex.Dispose();$usb.Dispose();exit}
$script:allowExit=$false
$form = [Windows.Forms.Form]::new()
$appVersion=([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'version.json'))|ConvertFrom-Json).Version
$form.Text = 'Hub PC Monitor v'+$appVersion+' - Direct USB'
$form.ClientSize = [Drawing.Size]::new(550,555)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font=[Drawing.Font]::new('Segoe UI',9)
$form.BackColor=[Drawing.ColorTranslator]::FromHtml('#0D1115')
$form.ForeColor=[Drawing.ColorTranslator]::FromHtml('#ECEFF1')
$select = [Windows.Forms.ComboBox]::new()
$select.SetBounds(20,20,340,28)
$select.DropDownStyle = 'DropDownList'
$view = [Windows.Forms.ComboBox]::new(); $view.SetBounds(20,20,510,28); $view.DropDownStyle='DropDownList'
$themeNames=@((-join ([char[]]@(0x6027,0x80FD,0x76D1,0x63A7,0x4E3B,0x9898))),(-join ([char[]]@(0x9ED8,0x8BA4,0x65F6,0x949F,0x4E3B,0x9898))),('DeepSeek '+[char]0x65F6+[char]0x949F),('ChatGPT '+[char]0x65F6+[char]0x949F+'+'+[char]0x4F59+[char]0x989D),'bongocat','战术频谱');$themeModes=@('Monitor','Clock','DeepSeek','ChatGPT','BongoCat','Spectrum')
$view.Items.AddRange($themeNames);$view.SelectedIndex=[array]::IndexOf($themeModes,$Mode)
$quotaToggle=[Windows.Forms.CheckBox]::new();$quotaToggle.Text=$quotaLabels.QueryBalance;$quotaToggle.SetBounds(380,65,160,35)
$quotaToggle.Checked=$script:queryChatGPTBalance;$quotaToggle.Visible=($Mode -eq 'ChatGPT')
$quotaToggle.Add_CheckedChanged({
    $script:queryChatGPTBalance=$quotaToggle.Checked -and $Mode -eq 'ChatGPT'
    $quotaReader.Dispose();$script:quotaReader=[CodexQuotaReader]::new($codexPath)
    $script:quota=$null;$script:lastQuotaLog=[DateTime]::MinValue;$script:lastPixels=$null
})
$bongoSelect=[Windows.Forms.Button]::new();$bongoSelect.Text='选择 BongoCat';$bongoSelect.SetBounds(380,65,150,35);$bongoSelect.Visible=($Mode -eq 'BongoCat')
$bongoSelect.Add_Click({
    $dialog=[Windows.Forms.OpenFileDialog]::new();$dialog.Title='选择已安装的 BongoCat.exe';$dialog.Filter='BongoCat.exe|BongoCat.exe';$dialog.CheckFileExists=$true
    try{if($dialog.ShowDialog($form) -eq 'OK'){
        $bongoPipeline.Stop();$bongoSource.ExecutablePath=$dialog.FileName;$bongoSource.Reset();Save-Preferences;$script:lastPixels=$null
        if($script:running){Update-Clock}else{Show-SelectedThemePreview}
    }}finally{$dialog.Dispose()}
})
$filterToggle=[Windows.Forms.CheckBox]::new();$filterToggle.Text='BongoCat 流畅优先（过滤细微像素变化）';$filterToggle.SetBounds(20,405,285,25)
$filterToggle.Checked=$script:bongoSmooth;$filterToggle.Visible=($Mode -eq 'BongoCat')
$filterToggle.Add_CheckedChanged({$script:bongoSmooth=$filterToggle.Checked;Save-Preferences;$colorToggle.Enabled=$script:bongoSmooth;$zoneToggle.Enabled=$script:bongoSmooth;$script:lastPixels=$null;$script:lastBongoExact=0.0;$script:bongoExactTop=0;$script:nextBongoExact=0.0; $script:spectrumRenderer=[TacticalSpectrum]::new();if($script:running){Update-Clock}})
$colorToggle=[Windows.Forms.CheckBox]::new();$colorToggle.Text='降低色彩精度（4096色）';$colorToggle.SetBounds(310,405,225,25)
$colorToggle.Checked=$script:bongoReduceColor;$colorToggle.Visible=($Mode -eq 'BongoCat');$colorToggle.Enabled=$script:bongoSmooth
$colorToggle.Add_CheckedChanged({$script:bongoReduceColor=$colorToggle.Checked;Save-Preferences;$script:lastPixels=$null;$script:lastBongoExact=0.0;$script:bongoExactTop=0;$script:nextBongoExact=0.0; $script:spectrumRenderer=[TacticalSpectrum]::new();if($script:running){Update-Clock}})
$priorityToggle=[Windows.Forms.CheckBox]::new();$priorityToggle.Text='Hub 优先（桌面角色 0% 显示）';$priorityToggle.SetBounds(20,433,285,25)
$priorityToggle.Checked=$script:bongoHubPriority;$priorityToggle.Visible=($Mode -eq 'BongoCat')
$priorityToggle.Add_CheckedChanged({
    $script:bongoHubPriority=$priorityToggle.Checked;Save-Preferences
    $bongoSource.HubPriority=($script:bongoHubPriority -and $Mode -eq 'BongoCat' -and $script:running)
    if($script:running){Update-Clock}else{Show-SelectedThemePreview}
})
$zoneToggle=[Windows.Forms.CheckBox]::new();$zoneToggle.Text='分区精度＋分批校正';$zoneToggle.SetBounds(310,433,225,25)
$zoneToggle.Checked=$script:bongoZoned;$zoneToggle.Visible=($Mode -eq 'BongoCat');$zoneToggle.Enabled=$script:bongoSmooth
$zoneToggle.Add_CheckedChanged({$script:bongoZoned=$zoneToggle.Checked;Save-Preferences;$script:lastPixels=$null;$script:bongoExactTop=0;$script:nextBongoExact=0.0; $script:spectrumRenderer=[TacticalSpectrum]::new();$script:lastBongoExact=0.0;if($script:running){Update-Clock}})
$parallelToggle=[Windows.Forms.CheckBox]::new();$parallelToggle.Text='后台捕获（仅保留最新画面）';$parallelToggle.SetBounds(20,461,510,25)
$parallelToggle.Checked=$script:bongoParallel;$parallelToggle.Visible=($Mode -eq 'BongoCat')
$parallelToggle.Add_CheckedChanged({$script:bongoParallel=$parallelToggle.Checked;$bongoPipeline.Stop();Save-Preferences;$script:lastPixels=$null;if($script:running){Update-Clock}})
$view.Add_SelectedIndexChanged({
    $script:Mode=$themeModes[$view.SelectedIndex];$script:sampler=[PcSampler]::new();Reset-Animation
    $quotaToggle.Visible=($script:Mode -eq 'ChatGPT')
    $bongoSelect.Visible=($script:Mode -eq 'BongoCat')
    $filterToggle.Visible=($script:Mode -eq 'BongoCat')
    $colorToggle.Visible=($script:Mode -eq 'BongoCat')
    $priorityToggle.Visible=($script:Mode -eq 'BongoCat')
    $zoneToggle.Visible=($script:Mode -eq 'BongoCat')
    $parallelToggle.Visible=($script:Mode -eq 'BongoCat')
    if($script:Mode -ne 'Spectrum'){$audioSpectrum.Stop()}
    if($script:Mode -ne 'BongoCat'){$bongoPipeline.Stop();$bongoSource.HubPriority=$false}
    if($script:Mode -ne 'ChatGPT'){$quotaToggle.Checked=$false}
    Save-Preferences
    if($script:running){Update-Clock}else{Show-SelectedThemePreview}
})
$start = [Windows.Forms.Button]::new(); $start.Text = 'Start display'; $start.SetBounds(20,65,160,35)
$stop = [Windows.Forms.Button]::new(); $stop.Text = 'Stop / release USB'; $stop.SetBounds(195,65,170,35); $stop.Enabled = $false
$preview = [Windows.Forms.PictureBox]::new(); $preview.SetBounds(20,190,510,210); $preview.SizeMode = 'Zoom'
$status = [Windows.Forms.Label]::new(); $status.SetBounds(20,500,510,50); $status.Text = 'Close the vendor GUI, then select your device.'
$screenControls=[Windows.Forms.GroupBox]::new();$screenControls.SetBounds(20,110,510,65);$screenControls.ForeColor=$form.ForeColor
$rotateLeft=[Windows.Forms.Button]::new();$rotateLeft.Text='向左旋转';$rotateLeft.SetBounds(10,23,150,30)
$rotateRight=[Windows.Forms.Button]::new();$rotateRight.Text='向右旋转';$rotateRight.SetBounds(180,23,150,30)
$rotateStep=[Windows.Forms.Button]::new();$rotateStep.Text='上下翻转 (180'+[char]0xB0+')';$rotateStep.SetBounds(350,23,150,30)
$screenControls.Controls.AddRange(@($rotateLeft,$rotateRight,$rotateStep))
function Update-ScreenControls {
    $screenControls.Text='屏幕控制  '+$script:rotation+[char]0xB0
}
function Apply-ScreenControls {
    Save-Preferences;Update-ScreenControls;$script:lastPixels=$null
    if($script:running){Update-Clock}else{Show-SelectedThemePreview}
}
$rotateLeft.Add_Click({$script:rotation=($script:rotation+270)%360;Apply-ScreenControls})
$rotateRight.Add_Click({$script:rotation=($script:rotation+90)%360;Apply-ScreenControls})
$rotateStep.Add_Click({$script:rotation=($script:rotation+180)%360;Apply-ScreenControls})
$form.Controls.AddRange(@($view,$screenControls,$start,$stop,$preview,$status,$quotaToggle,$bongoSelect,$filterToggle,$colorToggle,$priorityToggle,$zoneToggle,$parallelToggle))
foreach($button in @($start,$stop,$rotateLeft,$rotateRight,$rotateStep,$bongoSelect)) {
    $button.FlatStyle='Flat';$button.FlatAppearance.BorderSize=1
    $button.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#56616B')
    $button.BackColor=[Drawing.ColorTranslator]::FromHtml('#1C2228')
    $button.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#333C44')
    $button.FlatAppearance.MouseDownBackColor=[Drawing.ColorTranslator]::FromHtml('#46525C')
}
$start.BackColor=[Drawing.ColorTranslator]::FromHtml('#F4D35E');$start.ForeColor=[Drawing.Color]::Black
$start.FlatAppearance.BorderColor=$start.BackColor
$start.FlatAppearance.MouseOverBackColor=[Drawing.ColorTranslator]::FromHtml('#FFE28A')
$start.FlatAppearance.MouseDownBackColor=[Drawing.ColorTranslator]::FromHtml('#D5B648')
foreach($combo in @($view)){$combo.FlatStyle='Flat';$combo.BackColor=[Drawing.ColorTranslator]::FromHtml('#1C2228');$combo.ForeColor=$form.ForeColor}
$preview.BorderStyle='FixedSingle';$preview.BackColor=$form.BackColor
Update-ScreenControls
$status.ForeColor=[Drawing.ColorTranslator]::FromHtml('#97A1AA')
$timer = [Windows.Forms.Timer]::new(); $timer.Interval = 1000
$animationPump=[AnimationFramePump]::new($form,[Action]{Update-Clock})
$trayMenu=[Windows.Forms.ContextMenuStrip]::new()
$openMenu=$trayMenu.Items.Add('Open monitor')
$sensorMenu=$trayMenu.Items.Add('安装或修复 CPU 温度组件')
$null=$trayMenu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$exitMenu=$trayMenu.Items.Add('Exit')
$notify=[Windows.Forms.NotifyIcon]::new()
$notify.Icon=[Drawing.SystemIcons]::Application
if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'HubMonitor.ico')){$notify.Icon=[Drawing.Icon]::new((Join-Path $PSScriptRoot 'HubMonitor.ico'))}
$notify.Text='Hub PC Monitor'
$notify.ContextMenuStrip=$trayMenu
$notify.Visible=$true
function Show-Monitor {$form.Show();$form.WindowState='Normal';$form.ShowInTaskbar=$true;$form.Activate()}
$openMenu.Add_Click({Show-Monitor})
$sensorMenu.Add_Click({
    try{
        $info=[Diagnostics.ProcessStartInfo]::new('powershell.exe',('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Install-Sensors.ps1')+'"'))
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $null=[Diagnostics.Process]::Start($info)
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'CPU temperature')|Out-Null}
})
$notify.Add_DoubleClick({Show-Monitor})
$exitMenu.Add_Click({$script:allowExit=$true;$form.Close()})
$lifecycle=[Windows.Forms.Timer]::new();$lifecycle.Interval=1000
$connection=[HubReconnectState]::new()
$script:connecting=$false
$script:lastPanelWidth=320;$script:lastPanelHeight=170
$lifecycle.Add_Tick({
    if($exitSignal.WaitOne(0)){$exitMenu.PerformClick();return}
    if($showSignal.WaitOne(0)){Show-Monitor}
    if(-not $script:connecting -and $connection.ShouldAttempt([DateTime]::UtcNow,$script:running)){
        $connection.Failed([DateTime]::UtcNow)
        Refresh-Devices
        $target=$connection.SelectTarget([string[]]@($select.Items))
        if($target){$select.SelectedItem=$target;$start.PerformClick()}
        else{$status.Text='Device offline; waiting to reconnect the selected Hub. Use Refresh / Start to choose another device.'}
    }
})
$script:running = $false
function Write-ClockLog([string]$Message) {
    Add-Content -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'clock.log') -Value "$(Get-Date -Format o) $Message"
}
function Stop-Clock {
    $timer.Stop(); $animationPump.Stop(); $script:running = $false; $audioSpectrum.Stop(); $bongoPipeline.Stop(); $bongoSource.RestoreDesktop()
    $null=[HubUsb]::timeEndPeriod(1)
    try { $usb.Close() } catch { Write-ClockLog $_.Exception.Message }
    $script:lastPixels=$null
    $start.Enabled = $true; $stop.Enabled = $connection.Wanted; $select.Enabled = $true
}
function Update-Clock {
    if (-not $script:running) { return }
    $timer.Stop();$animationPump.Stop()
    $image = $null
    $tick=[Diagnostics.Stopwatch]::StartNew()
    try {
        Update-Voltage
        $image = New-ClockImage $usb.Width $usb.Height
        if($script:rotation -ne 0){
            $deviceImage=[ScreenOrientation]::Apply($image,$script:rotation,($Mode -in @('DeepSeek','ChatGPT')))
            try{Send-DisplayImage $deviceImage}finally{$deviceImage.Dispose()}
        }else{Send-DisplayImage $image}
        if($Mode -eq 'ChatGPT' -and $script:quota -and $script:quota.Success -and $script:quota.UpdatedUtc -ne $script:lastQuotaLog){
            Write-ClockLog "Codex quota refreshed: plan=$($script:quota.Plan); $($script:quota.Primary); $($script:quota.Secondary); status=$($script:quota.Status)"
            $script:lastQuotaLog=$script:quota.UpdatedUtc
        }
        if ($script:displayUpdates -eq 1 -or $script:displayUpdates % 600 -eq 0) { Write-ClockLog "Device ACK $($usb.LastReply), packets=$($usb.Frames), regions=$($usb.RegionFrames), updates=$script:displayUpdates, voltageMv=$($usb.VoltageMillivolts), cpuC=$($script:temperatures.Cpu), gpuC=$($script:temperatures.Gpu)" }
        $old = $preview.Image; $preview.Image = $image; $image = $null
        if ($old) { $old.Dispose() }
        $fps=$script:displayUpdates/[Math]::Max(0.001,$script:displayWatch.Elapsed.TotalSeconds)
        $status.Text = "SN: $($usb.Serial)  |  $($usb.Width)x$($usb.Height)  |  $($usb.HardwareVariant)`nACK: $($usb.LastReply) | Regions: $($usb.RegionFrames) | Render: $($fps.ToString('F1')) FPS"
    } catch {
        $message = $_.Exception.Message; Write-ClockLog $message
        Stop-Clock;$connection.Failed([DateTime]::UtcNow);$status.Text = 'Connection lost; reconnecting. '+$message
    } finally {
        if ($image) { $image.Dispose() }
        if ($script:running) {
            $timer.Interval=if($Mode -in @('Monitor','Clock','BongoCat','Spectrum')){[int][Math]::Max(1,[Math]::Ceiling(1000/$(if($Mode -in @('Clock','Spectrum')){120.0}elseif($Mode -eq 'BongoCat'){$(if($script:bongoParallel){60.0}else{30.0})}else{60.0})-$tick.Elapsed.TotalMilliseconds))}else{1000}
            if($Mode -in @('BongoCat','Spectrum')){$animationPump.Schedule($timer.Interval)}else{$timer.Start()}
        }
    }
}
function Show-SelectedThemePreview {
    $image=New-ClockImage $script:lastPanelWidth $script:lastPanelHeight
    $old=$preview.Image;$preview.Image=$image;if($old){$old.Dispose()}
}
function Refresh-Devices {
    try {
        $previous=[string]$select.SelectedItem
        if(-not $script:running){
            try{$usb.Dispose()}catch{Write-ClockLog $_.Exception.Message}
            $script:usb=[HubUsb]::new()
            $script:lastPixels=$null
        }
        $select.Items.Clear()
        foreach ($sn in $usb.ListDevices()) { $null = $select.Items.Add($sn) }
        if($previous -and $select.Items.Contains($previous)){$select.SelectedItem=$previous}
        elseif ($select.Items.Count -eq 1) { $select.SelectedIndex = 0 }else{$select.SelectedIndex=-1}
        $status.Text = "Found $($select.Items.Count) device(s). Close vendor GUI before starting."
        if ($select.Items.Count -eq 0) { $status.Text += "`n$($usb.Diagnostics)" }
    } catch { $status.Text = $_.Exception.Message }
}
$start.Add_Click({
    if($script:running -or $script:connecting){return}
    $script:connecting=$true
    $connection.Start($connection.TargetSerial)
    try {
        Refresh-Devices
        if($select.Items.Count -gt 1 -and -not $select.SelectedItem){
            $picker=[Windows.Forms.Form]::new();$picker.Text='Choose connected Hub';$picker.ClientSize=[Drawing.Size]::new(390,170);$picker.StartPosition='CenterParent'
            $list=[Windows.Forms.ListBox]::new();$list.SetBounds(15,15,360,95)
            foreach($sn in $select.Items){$null=$list.Items.Add($sn)}
            $ok=[Windows.Forms.Button]::new();$ok.Text='Connect';$ok.SetBounds(260,120,110,30)
            $ok.Add_Click({if($list.SelectedIndex -ge 0){$picker.DialogResult='OK'}})
            $picker.Controls.AddRange(@($list,$ok))
            try{if($picker.ShowDialog($form) -eq 'OK'){$select.SelectedIndex=$list.SelectedIndex}}finally{$picker.Dispose()}
        }
        if (-not $select.SelectedItem) { throw 'No device selected. Close vendor GUI, connect USB, then click Start display.' }
        $status.Text = 'Connecting...'
        $connection.Start([string]$select.SelectedItem)
        Connect-Hub ([string]$select.SelectedItem)
        $script:lastPanelWidth=$usb.Width;$script:lastPanelHeight=$usb.Height
        $script:sampler=[PcSampler]::new()
        Reset-Animation
        $null=[HubUsb]::timeBeginPeriod(1)
        Write-ClockLog "Connected $($usb.Serial): $($usb.Identity)"
        Write-ClockLog "Hub: $($usb.HardwareVariant), $($usb.Width)x$($usb.Height), source=$($usb.IdentitySource), theme=$Mode"
        Write-ClockLog "Hardware: CPU=$($hardwareInfo.CpuDisplay); RAM=$($hardwareInfo.MemoryDisplay); GPU=$($hardwareInfo.GpuName)"
        $script:running = $true; $start.Enabled = $false; $stop.Enabled = $true; $select.Enabled = $false
        Update-Clock
    } catch { Stop-Clock;$connection.Failed([DateTime]::UtcNow);$status.Text = $_.Exception.Message; Write-ClockLog $_.Exception.Message }
    finally{$script:connecting=$false}
})
$stop.Add_Click({$connection.Stop();Stop-Clock; $status.Text = 'Stopped; USB released.' })
$timer.Add_Tick({ Update-Clock })
$form.Add_Shown({
    Refresh-Devices
    if ($select.Items.Count -eq 1) { $start.PerformClick() }
    if($Tray){$form.Hide();$form.ShowInTaskbar=$false}
    $lifecycle.Start()
})
$form.Add_FormClosing({param($sender,$eventArgs)
    if(-not $script:allowExit -and $eventArgs.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing){$eventArgs.Cancel=$true;$form.Hide();$form.ShowInTaskbar=$false;return}
    Stop-Clock
})
$form.Add_Resize({if($form.WindowState -eq 'Minimized'){$form.Hide();$form.ShowInTaskbar=$false}})
try { [Windows.Forms.Application]::Run($form) }
finally { $lifecycle.Stop();$lifecycle.Dispose();$notify.Visible=$false;$notify.Dispose();$trayMenu.Dispose();$animationPump.Dispose();$timer.Dispose();$audioSpectrum.Dispose();$bongoPipeline.Dispose();$bongoSource.Dispose();$loadReader.Dispose();$temperatureReader.Dispose();$quotaReader.Dispose(); $usb.Dispose(); if ($preview.Image) { $preview.Image.Dispose() };if($script:deepseekBackground){$script:deepseekBackground.Dispose()};if($script:chatgptBackground){$script:chatgptBackground.Dispose()};if($script:chatgptDisplay){$script:chatgptDisplay.Dispose()};if($script:chatgptOriginal){$script:chatgptOriginal.Dispose()}; $form.Dispose();$showSignal.Dispose();$exitSignal.Dispose();$instanceMutex.ReleaseMutex();$instanceMutex.Dispose() }
