# 错误输出区域检测接入 Runner

你补充的信息是：

- 正常输出区域和错误输出区域不一样。
- 正常输出区域可能包含错误输出区域。
- 如果正常输出很少，错误输出仍会落到固定区域。
- 错误输出文本可以拖选复制，拖选复制理论上不影响复现。

这意味着我们可以只检测固定的错误输出区域，不需要识别正常输出全文。

## 先单独校准错误区域

先让界面出现 `Cannot connect to API`，再用相对坐标拖选错误输出区域：

```powershell
cd G:\crash
.\scripts\read-agent-output-text.ps1 `
  -ProcessName codeArts-agent `
  -StartX 780 `
  -StartY 160 `
  -EndX 1600 `
  -EndY 260 `
  -DetectPrefix "Cannot connect to API" `
  -OutFile .\.black-screen-repro\agent-output-check.json
```

坐标都是相对 IDE 主窗口左上角。

成功时会输出类似：

```json
{"isMatch":true,"firstLine":"Cannot connect to API..."}
```

如果 `textLength=0` 或 `firstLine` 不是目标文本，说明拖选坐标不准，或者该区域不可复制。

## 接入 stable runner

`repro-stable-runner.ps1` 已支持错误区域检测和重试：

```powershell
.\scripts\repro-stable-runner.ps1 `
  -ProcessName codeArts-agent `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentClickSequence "120,160;1450,980" `
  -PromptEachEpisode `
  -AgentWaitMode visualStable `
  -AgentOutputX 780 `
  -AgentOutputY 160 `
  -AgentOutputWidth 1050 `
  -AgentOutputHeight 760 `
  -CheckAgentError `
  -AgentErrorStartX 780 `
  -AgentErrorStartY 160 `
  -AgentErrorEndX 1600 `
  -AgentErrorEndY 260 `
  -AgentErrorMaxRetries 1 `
  -AgentCooldownSeconds 120 `
  -HiddenSeconds 180 `
  -PostRestoreObserveSeconds 600 `
  -PostRestoreCheckIntervalSeconds 5
```

流程：

```text
投喂提示词
等待输出区域视觉稳定
拖选复制错误区域
如果文本以 Cannot connect to API 开头：
  判定本轮 Agent 输出失败
  重新执行点击序列和投喂
  最多重试 AgentErrorMaxRetries 次
如果仍失败：
  跳过该 episode，不把它计入有效复现轮
```

## 注意

- 错误区域检测会改变当前文本选择区域，有轻微 UI 干扰；建议只在 Agent 输出阶段使用，不要在已经命中黑屏后使用。
- 先单独校准 `read-agent-output-text.ps1`，确认可复制后再接入 runner。
- 如果错误区域固定，正常输出区域不同不影响检测。
