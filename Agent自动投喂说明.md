# Agent 自动投喂说明

你们当前进程名按 `codeArts-agent` 处理，脚本默认也是这个名字。

## 为什么之前 ClickX/Y 可能没输入

常见原因：

1. 坐标不是相对 IDE 主窗口左上角，而是屏幕绝对坐标。
2. IDE 没有处于普通最大化状态，窗口位置/尺寸不同导致坐标偏了。
3. 点击点没有真正聚焦输入框。
4. 老会话有 bug，输入框失效，需要先点“新会话/打开会话”。
5. IDE 是管理员权限启动，PowerShell 不是管理员，Windows 不允许低权限进程向高权限窗口发送输入。
6. 新建会话后输入框位置变化，固定坐标已经不再指向输入框。

## 乱码问题

提示词文件按 UTF-8 读取。之前乱码通常是 PowerShell 5.1 用系统 ANSI 读取 UTF-8 文件导致。现在 `send-agent-prompt.ps1` 已改为：

```powershell
[System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
```

如果仍有乱码，先用纯 ASCII 提示词测试，确认不是输入控件本身的问题。

## 先用最稳的倒计时模式测试

先不要直接跑完整复现。也先不要让脚本最大化和点击坐标。用倒计时模式：

```powershell
cd G:\crash
.\scripts\send-agent-prompt.ps1 `
  -PromptFile .\agent-prompts\01-generate-feature.txt `
  -UseCurrentForeground `
  -CountdownSeconds 5 `
  -SubmitKeys "{ENTER}"
```

执行后 5 秒内，手工切到 IDE，点到 Agent 输入框。倒计时结束后脚本只负责粘贴和回车。

如果这个模式都不能输入，说明不是坐标问题，优先检查：

1. PowerShell 是否和 IDE 权限一致。如果 IDE 是管理员，PowerShell 也要管理员。
2. 输入框是否真的可输入，旧会话是否已经失效。
3. Electron/控件是否拦截了系统粘贴。

## 坐标模式前先量坐标

使用下面脚本读取鼠标相对 IDE 主窗口左上角的位置：

```powershell
.\scripts\get-relative-mouse.ps1 -ProcessName codeArts-agent -Samples 10 -IntervalMs 1000
```

把鼠标放到“新会话/打开会话”按钮、输入框位置，记录 `relative=(x,y)`。

## 坐标投喂测试

如果需要先点会话按钮，再点输入框：

```powershell
cd G:\crash
.\scripts\send-agent-prompt.ps1 `
  -ProcessName codeArts-agent `
  -PromptFile .\agent-prompts\01-generate-feature.txt `
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
  -ClickX 1450 `
  -ClickY 980 `
  -SubmitKeys "{ENTER}"
```

如果粘贴偶发失败，可以加重试：

```powershell
-PasteRetries 2
```

## 判断当前焦点是否真的可输入

可以用输入校验模式。它会在当前焦点里写入一个 ASCII 探针，复制回来比较。

注意：如果焦点点错，它会把探针写到错误位置，所以只用于单独校准，不要一开始放进长时间复现 runner。

倒计时手工聚焦输入框后校验：

```powershell
.\scripts\send-agent-prompt.ps1 `
  -PromptFile .\agent-prompts\01-generate-feature.txt `
  -UseCurrentForeground `
  -CountdownSeconds 5 `
  -VerifyInputFocus `
  -SubmitKeys ""
```

坐标点击后校验：

```powershell
.\scripts\send-agent-prompt.ps1 `
  -ProcessName codeArts-agent `
  -PromptFile .\agent-prompts\01-generate-feature.txt `
  -ClickSequence "120,160;1450,980" `
  -VerifyInputFocus `
  -SubmitKeys ""
```

如果校验失败，说明当前焦点不是可输入框，或者输入框已失效。此时不要跑完整 runner，先调整：

1. 点击序列里先点新会话/打开会话。
2. 重新用 `get-relative-mouse.ps1` 量输入框坐标。
3. 确认输入框有光标。
4. 确认 PowerShell 和 IDE 权限一致。

## 新会话导致输入框位置变化怎么办

不要把“新会话按钮”和“输入框”想成永远固定的两个点。新会话后 UI 可能重新布局。

更稳的做法：

1. 用 `ClickSequence` 点“新会话/打开会话”。
2. 等 UI 稳定后，再点输入框位置。
3. 如果输入框位置变化明显，先不用完整 runner，单独调 `send-agent-prompt.ps1`。
4. 如果 UI 每次变化都很大，自动投喂只能作为半自动：用 `-UseCurrentForeground -CountdownSeconds 5`，人工点输入框，脚本粘贴提交。

## 跑稳定复现时使用

会话容易失效时，建议每轮都先点击新会话/打开会话，再点击输入框。不要先加 `-MaximizeBeforeAgentInput`，除非你确认最大化不会改变 UI 布局：

```powershell
.\scripts\repro-stable-runner.ps1 `
  -ProcessName codeArts-agent `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentClickSequence "120,160;1450,980" `
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
