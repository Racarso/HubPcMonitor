# 音乐律动主题（0.4.33）

在主题列表选择“音乐律动”。黑黄配色、24 段对数频谱、右上角本地时钟、灰色峰值标记；黄色柱快速上升、缓慢回落。320×170 与 320×240 均可绘制，沿用屏幕旋转，电脑预览保持正常方向。

通过 Windows WASAPI shared-mode loopback 在后台读取默认播放设备的混音，不使用麦克风，不保存录音，不上传音频。无需音乐播放器插件或额外音频驱动。使用系统默认输出（console role），不读取被单独路由到其他输出设备的声音。约每 2 秒检查默认输出变更，失效后重连。切换主题、停止显示和退出会停止采集。

2048 点 Hann 窗 FFT，24 段约 50 Hz 至 16 kHz 的对数频带；使用固定 -60 至 0 dBFS 映射，并非校准音量计。左右声道取绝对值较大者，防止反相抵消，故频谱是可视化近似值。没有声音时衰减到零；静音、音量为零、输出设备不可用或受保护音频可能无法产生柱形。未连接时标记 WAITING，采集异常显示 NO AUDIO，LIVE 表示采集已连接。

绘制调度目标最高 60 FPS，USB 使用变化区域和串行 ACK；实际更新速度取决于变化面积和设备传输速度，不保证 60 FPS。没有变化时不重复发送像素。

验证：六种主题在两种分辨率及旋转下的绘制自检；静音输入与 1 kHz 合成信号 FFT 定位；实际 48 kHz 双声道 float32 回环数据包与停止/重启。当前实机默认输出音量为 0 且静音，因此真实测试音驱动柱形的检查跳过，没有改动用户音量。运行 `test-audio-spectrum.ps1 -Live` 可在取消静音后复测（会播放短暂低音量测试音）。

WASAPI 回环机制参考：[Microsoft Loopback Recording](https://learn.microsoft.com/en-us/windows/win32/coreaudio/loopback-recording)。

0.4.34: Spectrum now fills partial segments with a fractional-brightness edge instead of jumping in 5-pixel steps. FFT window coefficients and per-stage rotation constants are precomputed; analysis scheduling is approximately 8ms where audio delivery permits. Spectrum rendering targets up to 120 FPS, uses the exact adaptive region sender without the unnecessary threshold-zero filter copy. An experimental column planner was rejected: identical replay payload and packet counts showed no meaningful benefit. Controlled 99-frame synthetic replay at the app's 1ms timer setting, Old60/New120/New120/Old60: 32.52/33.77/33.84/33.47 FPS (average 32.99 vs 33.80), P95 send work approximately 26ms. These tests replay the same newly smoothed frames, exclude live capture/UI and do not compare old versus new visual geometry. Main improvement is smaller animation steps, not a guaranteed large FPS increase. See spectrum-planner-benchmark.json. Backups AudioSpectrum-0.4.33.backup.cs and UsbClock-0.4.33.backup.cs are not packaged.
