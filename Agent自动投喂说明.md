# Agent 自动投喂说明

你们当前进程名按 `codeArts-agent` 处理，脚本默认也是这个名字。

## 为什么之前 ClickX/Y 可能没输入

常见原因：

1. 坐标不是相对 IDE 主窗口左上角，而是屏幕绝对坐标。
2. IDE 没有处于普通最大化状态，窗口位置/尺寸不同导致坐标偏了。
3. 点击点没有真正聚焦输入框。
4. 老会话有 bug，输入框失效，需要先点“新会话/打开会话”。
5. IDE 是管理员权限启动，PowerShell 不是管理员，Windows 不允许低权限进程向高权限窗口发送输入。

## 单次投喂测试

先不要直接跑完整复现。先测试能否自动输入。

如果需要先点会话按钮，再点输入框：

```powershell
cd G:\crash
.\scripts\send-agent-prompt.ps1 `
  -ProcessName codeArts-agent `
  -PromptFile .\agent-prompts\01-generate-feature.txt `
  -MaximizeBeforeInput `
  -ClickSequence "120,160;1450,980" `
  -SubmitKeys "{ENTER}"
```

`ClickSequence` 是相对 IDE 主窗口左上角的坐标序列：

```text
"会话按钮X,会话按钮Y;输入框X,输入框Y"
```

如果只需要点击输入框：

```powershell
.\scripts\send-agent-prompt.ps1 `
  -ProcessName codeArts-agent `
  -PromptFile .\agent-prompts\01-generate-feature.txt `
  -MaximizeBeforeInput `
  -ClickX 1450 `
  -ClickY 980 `
  -SubmitKeys "{ENTER}"
```

如果粘贴偶发失败，可以加重试：

```powershell
-PasteRetries 2
```

## 跑稳定复现时使用

会话容易失效时，建议每轮都先点击新会话/打开会话，再点击输入框：

```powershell
.\scripts\repro-stable-runner.ps1 `
  -ProcessName codeArts-agent `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentClickSequence "120,160;1450,980" `
  -MaximizeBeforeAgentInput `
  -PromptEachEpisode `
  -AgentRunSeconds 90 `
  -AgentCooldownSeconds 180 `
  -HiddenSeconds 180 `
  -PostRestoreObserveSeconds 600 `
  -PostRestoreCheckIntervalSeconds 5
```

坐标需要你们按真实 UI 调整：

- 第一个点：能打开一个可输入会话的位置。
- 第二个点：Agent 输入框位置。

## 如何量坐标

坐标是相对 IDE 主窗口左上角。

可以手工用截图工具量，也可以先让 IDE 普通最大化到目标屏幕，然后用鼠标位置工具读取屏幕坐标，再减去 IDE 窗口左上角屏幕坐标。

如果不确定，先把 `ClickSequence` 简化成只点输入框，确认粘贴能进去，再加“新会话/打开会话”的点。
