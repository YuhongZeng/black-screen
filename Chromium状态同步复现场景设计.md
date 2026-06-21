# Chromium 状态同步问题的复现场景设计

当前最高怀疑不是“IPC 多”本身，而是 Chromium/Electron 在窗口状态切换时的显示状态同步问题：

```text
visible/active
  -> occluded 或 minimized 或 hidden
  -> Webview/workbench paint/rAF 停止或降级
  -> 后台期间 surface / frame / software output 被回收或陈旧
  -> restore/maximize/show
  -> WasShown / SetVisible / LocalSurfaceId / FrameSink / Viz 合成没有完全同步
  -> IDE 顶层 Windows 窗口黑屏或显示旧画面
```

因此 episode 需要围绕“状态同步断点”设计，而不是只围绕最大化/最小化。

## 需要覆盖的状态断点

1. **Occluded 但未 minimized**
   - 用小窗口遮挡 IDE。
   - 目的：验证不是只有 `SC_MINIMIZE` / `WasHidden` 才触发，普通遮挡也会让显示链路进入异常状态。

2. **Minimized / hidden**
   - 最小化 IDE。
   - 目的：验证显式 hidden -> shown 的 `WasHidden/WasShown` 链路。

3. **Surface eviction / working set trim**
   - 遮挡或最小化期间 trim working set。
   - 目的：模拟长时间后台后 surface/shared bitmap/software output 被回收。

4. **外部资源压力**
   - 遮挡或最小化期间打开网页、构建项目、制造内存压力。
   - 目的：模拟“agent 已跑完，用户做别的事后复现”的现场。

5. **Agent 活跃态与 Agent 已结束态**
   - 活跃态：恢复时 agent 仍在输出/编辑。
   - 已结束态：agent 输出结束，但 IDE 长时间处于后台/遮挡，之后用户打开网页或做别的事再恢复。
   - 目的：区分“生成代码过程触发”还是“生成代码留下的 surface 状态 + 后续系统压力触发”。

6. **Visual properties / LocalSurfaceId churn**
   - 后续可加入跨屏/DPI/DisplaySwitch。
   - 目的：验证 `UpdateVisualProperties`、`LocalSurfaceId`、FrameSink 重新同步。

## 4 个 episode 的理由

### E1：小窗口遮挡

```powershell
.\scripts\repro-episode.ps1 -ProcessName Code -Loops 10 -WarmupSeconds 60 -CoverSeconds 300
```

理由：直接覆盖“被小窗口遮挡也会复现”的现场。它不依赖最小化，因此更能验证 occlusion/covered window 路径是否会破坏 Chromium 的可见性/合成状态同步。

### E2：小窗口遮挡 + WorkingSet Trim

```powershell
.\scripts\repro-episode.ps1 -ProcessName Code -Loops 10 -WarmupSeconds 60 -CoverSeconds 180 -TrimWorkingSet
```

理由：如果状态同步问题需要“后台一段时间后资源被回收”，trim working set 可以把等待时间压短。它主要验证 surface/shared bitmap/software output 陈旧或被回收后，restore 是否漏掉重建。

### E3：小窗口遮挡 + 内存压力/打开网页

```powershell
.\scripts\repro-episode.ps1 -ProcessName Code -Loops 10 -WarmupSeconds 60 -CoverSeconds 180 -MemoryPressureMb 4096 -MemoryPressureSeconds 60
```

理由：对应“agent 已经跑完，我打开网页/做别的事情也会复现”。这说明触发不一定发生在 agent 正在输出时，而可能是 agent 造成的复杂 surface 状态留在后台，后续系统资源压力促使 surface eviction，恢复时状态没同步。

也可以加打开网页：

```powershell
.\scripts\repro-episode.ps1 -ProcessName Code -Loops 10 -WarmupSeconds 60 -CoverSeconds 180 -OpenUrlDuringHidden "https://example.com"
```

### E4：最小化 + Trim + 内存压力

```powershell
.\scripts\repro-episode.ps1 -ProcessName Code -Loops 10 -WarmupSeconds 60 -CoverSeconds 180 -UseMinimize -TrimWorkingSet -MemoryPressureMb 4096 -MemoryPressureSeconds 60
```

理由：这是显式 hidden/show 路径的强刺激。它用于和 E1/E2/E3 对照：如果 E4 明显更容易复现，`WasHidden/WasShown` 链路嫌疑更大；如果 E1/E2 也能复现，说明普通遮挡/后台也足以破坏合成状态。

## Agent 任务自动投喂

每轮都手工检查和输入提示词会污染复现，也浪费时间。现在提供了：

```powershell
.\scripts\send-agent-prompt.ps1
```

它支持：

- 把 IDE 置前。
- 可选发送快捷键聚焦 Agent 输入框。
- 可选点击窗口内坐标。
- 粘贴提示词。
- 回车提交。

示例 1：如果 Agent 输入框已经有快捷键，例如 `Ctrl+Shift+A`：

```powershell
.\scripts\repro-episode.ps1 `
  -ProcessName Code `
  -AgentPromptFile .\agent-prompts\repro-task.txt `
  -AgentFocusKeys "^+a" `
  -PromptBeforeEachLoop `
  -Loops 10 `
  -CoverSeconds 180 `
  -TrimWorkingSet
```

示例 2：如果没有快捷键，可以用相对窗口坐标点击输入框：

```powershell
.\scripts\repro-episode.ps1 `
  -ProcessName Code `
  -AgentPromptFile .\agent-prompts\repro-task.txt `
  -AgentClickX 1450 `
  -AgentClickY 980 `
  -PromptBeforeEachLoop `
  -Loops 10 `
  -CoverSeconds 180
```

坐标是相对 IDE 主窗口左上角。第一次需要人工量一下输入框位置。

## 更合理的状态同步复现矩阵

建议按下面顺序跑，不要一次堆太多变量：

| 编号 | Agent 状态 | 窗口状态 | 后台扰动 | 判断 |
|---|---|---|---|---|
| S1 | 活跃输出 | 小窗口遮挡 | 无 | 单纯 occlusion 是否足够 |
| S2 | 活跃输出 | 小窗口遮挡 | trim | surface 回收是否加速 |
| S3 | 活跃输出 | 小窗口遮挡 | 内存压力/打开网页 | 用户做别的事是否加速 |
| S4 | 已结束 | 小窗口遮挡 | 内存压力/打开网页 | agent 结束后是否仍能触发 |
| S5 | 活跃输出 | 最小化 | trim + 内存压力 | WasHidden/WasShown 强路径 |
| S6 | 已结束 | 最小化 | trim + 内存压力 | 后台 stale surface 强路径 |

如果 S4/S6 能复现，说明黑屏不要求 agent 正在输出，真实触发更可能是“插件复杂 surface 状态残留 + 后续 Chromium/DWM 资源回收 + restore 状态同步失败”。

## 命中后的判断

每轮恢复后 `test-window-black.ps1` 会截图并输出 `blackRatio`。如果命中：

1. 不要移动/resize IDE。
2. 先保留 episode 目录。
3. 再抓 main/gpu/renderer dump。
4. 再保存 Perfetto trace。
5. 最后再尝试 resize 或 kill GPU 验证是否恢复。
