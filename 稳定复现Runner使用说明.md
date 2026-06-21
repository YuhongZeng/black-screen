# 稳定复现 Runner 使用说明

这个 runner 的目标不是保证 100% 复现，而是把偶发现象变成可统计、可对齐时间线的 episode。

核心能力：

- 自动保持系统和显示器不睡眠。
- 自动投喂 Agent 提示词。
- 支持小窗口遮挡或最小化。
- 默认按 Windows 普通最大化恢复到当前显示器工作区，不是全屏独占。
- 支持 Agent 活跃阶段和结束后的冷却阶段。
- 支持打开本地网页压力页、trim working set、内存压力。
- 恢复后持续观察，不只截图一次。
- 每一步写 `events.ndjson`，每次截图写 `black-check-xxxx.json`。

## 屏幕能不能息屏

基线实验必须保持亮屏、未锁屏。

原因：

1. 我们要研究的是窗口 visible/occluded/hidden 到 restore 的 Chromium/Viz 状态同步。
2. 息屏、锁屏、睡眠会引入 Windows session、DWM、显示设备重建路径，这是另一组变量。
3. 当前截图判黑依赖屏幕可见内容，息屏后截图结果不可靠。

所以默认 runner 会调用 `SetThreadExecutionState` 保持系统和显示器亮着。

如果后续要专门验证锁屏/息屏路径，再单独设计实验，不要和基线混在一起。

## 推荐第一轮：最接近真实场景，无额外压力

如果 Agent 输入框有快捷键，例如 `Ctrl+Shift+A`：

```powershell
cd G:\crash
.\scripts\repro-stable-runner.ps1 `
  -ProcessName Code `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentFocusKeys "^+a" `
  -PromptEachEpisode `
  -AgentRunSeconds 90 `
  -AgentCooldownSeconds 180 `
  -HiddenSeconds 180 `
  -PostRestoreObserveSeconds 600 `
  -PostRestoreCheckIntervalSeconds 5
```

如果没有快捷键，用坐标点击 Agent 输入框：

```powershell
.\scripts\repro-stable-runner.ps1 `
  -ProcessName Code `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentClickX 1450 `
  -AgentClickY 980 `
  -PromptEachEpisode `
  -AgentRunSeconds 90 `
  -AgentCooldownSeconds 180 `
  -HiddenSeconds 180 `
  -PostRestoreObserveSeconds 600 `
  -PostRestoreCheckIntervalSeconds 5
```

## 第二轮：只加打开网页

```powershell
.\scripts\repro-stable-runner.ps1 `
  -ProcessName Code `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentFocusKeys "^+a" `
  -PromptEachEpisode `
  -AgentRunSeconds 90 `
  -AgentCooldownSeconds 180 `
  -HiddenSeconds 180 `
  -OpenLocalStressPage `
  -PostRestoreObserveSeconds 600 `
  -PostRestoreCheckIntervalSeconds 5
```

这验证“agent 结束后，用户打开网页/做别的事”是否提高复现率。

## 第三轮：只加 trim

```powershell
.\scripts\repro-stable-runner.ps1 `
  -ProcessName Code `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentFocusKeys "^+a" `
  -PromptEachEpisode `
  -AgentRunSeconds 90 `
  -AgentCooldownSeconds 180 `
  -HiddenSeconds 180 `
  -TrimWorkingSet `
  -PostRestoreObserveSeconds 600 `
  -PostRestoreCheckIntervalSeconds 5
```

这验证 working set trim 是否能提高复现率。它不是根因，只是 surface/software output 回收的加速器。

## 第四轮：最后才加内存压力

```powershell
.\scripts\repro-stable-runner.ps1 `
  -ProcessName Code `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentFocusKeys "^+a" `
  -PromptEachEpisode `
  -AgentRunSeconds 90 `
  -AgentCooldownSeconds 180 `
  -HiddenSeconds 180 `
  -MemoryPressureMb 4096 `
  -MemoryPressureSeconds 60 `
  -PostRestoreObserveSeconds 600 `
  -PostRestoreCheckIntervalSeconds 5
```

只有前几轮都没有信号时再跑这个。否则内存压力容易污染判断。

## 输出

每次运行会创建：

```text
.black-screen-repro/stable-runs/run_yyyyMMdd_HHmmss/
  events.ndjson
  summary.json
  episode_001/
    black-check-0001.json
    window-shot-0001.png
    ...
```

重点看：

- `events.ndjson`：每一步时间线。
- `summary.json`：每轮是否命中、最大黑色比例、恢复后多久命中。
- `black-check-xxxx.json`：每次截图判黑结果。

如果命中，先不要 resize，也不要 kill GPU。先保留目录，再抓 dump/trace。
