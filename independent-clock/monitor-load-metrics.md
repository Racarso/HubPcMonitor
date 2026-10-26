# 性能监控排版与采集（0.4.36）

- 第一行：`CPU 35% (55°C)` 与原有 RAM 使用率/容量。
- 第二行：`CPU 3.79GHz` 与 `GPU 35%`，保留平滑进度条。
- 底部配置和输入电压保持原位置；屏幕上取消独立的 CPU/GPU 温度卡片。

CPU 主频是 Windows `Processor Information(_Total)` 的 `Processor Frequency`（基准 MHz）乘以 `% Processor Performance` 得到的 GHz 估计值，接近任务管理器的速度口径，采样间隔、处理器实现可导致差异，不宣称逐字一致。主频条按相对基准频率填充，睿频超过基准时条形填满，GHz 数值仍显示实际估计值。保留原有 GetSystemTimes CPU 时间占用率。

GPU 读取 `GPU Engine(*)\Utilization Percentage`，先按适配器和引擎合并各进程，再取最忙引擎；多显卡时取最忙适配器的最忙引擎，不将不同引擎直接相加。GPU 占用是机器范围值，并未绑定某一张配置名称。口径参考 [Microsoft GPU Task Manager](https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/)。

PDH 使用 [PdhAddEnglishCounterW](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhaddenglishcounterw)，后台线程每秒采样，不安装新驱动或服务。尚未就绪、计数器缺失或超过 4 秒未更新时显示 `--`，不会拿温度或固定值替代占用率。CPU 温度仍来自已有温度采集组件。

验证：GPU 按引擎聚合及缺失值测试、全部主题两种分辨率/旋转绘制自检，本机只读实测约 3.79GHz / GPU 34.8%。实际数值持续变化。

## v0.5.1
CPU frequency card now displays range percent plus (current GHz), using the verified model's base=0%, maximum turbo=100%, clamped outside that range. Missing/unknown models show --% but retain current GHz. This is not utilization or percent of maximum frequency. The baseline metadata comes from cpu-frequency-profiles.json (8 initial verified models with source URLs). Hybrid CPUs use P-core base and maximum advertised turbo as a reference; averaged PDH frequency is not a per-core peak. GPU card appends existing GPU temperature in parentheses. Tests cover all profiles, midpoint, clamping, missing/equal endpoints and exact suffix matching. Live i7-4790 example: 3.8037GHz -> 50.92% for 3.6-4.0GHz.
