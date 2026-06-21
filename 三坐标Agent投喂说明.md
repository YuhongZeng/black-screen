# 三坐标 Agent 投喂说明

你们的 Agent 输入有三个固定坐标：

1. 新建会话按钮。
2. 新建会话后的第一次输入框。
3. 已经输入过以后，再次输入的位置。

runner 已支持显式参数：

```powershell
-AgentNewChatClickX
-AgentNewChatClickY
-AgentFirstInputClickX
-AgentFirstInputClickY
-AgentFollowupInputClickX
-AgentFollowupInputClickY
```

## 行为

每个 episode 的第一次投喂：

```text
点击新建会话
点击第一次输入框
粘贴提示词
回车
```

如果检测到 `Cannot connect to API` 并重试：

```text
点击新建会话
点击后续输入框
粘贴提示词
回车
```

## 示例

假设坐标是：

```text
新建会话：120,160
第一次输入框：1450,980
后续输入框：1450,920
```

命令：

```powershell
cd G:\crash
.\scripts\repro-stable-runner.ps1 `
  -ProcessName codeArts-agent `
  -WindowMode cover `
  -RestoreMode maximize `
  -Episodes 10 `
  -AgentPromptDir .\agent-prompts `
  -AgentNewChatClickX 120 `
  -AgentNewChatClickY 160 `
  -AgentFirstInputClickX 1450 `
  -AgentFirstInputClickY 980 `
  -AgentFollowupInputClickX 1450 `
  -AgentFollowupInputClickY 920 `
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

如果不使用错误检测重试，也会每个 episode 用“新建会话 + 第一次输入框”。

## 坐标校准

使用：

```powershell
.\scripts\get-relative-mouse.ps1 -ProcessName codeArts-agent -Samples 10 -IntervalMs 1000
```

鼠标依次放到三个位置，记录 `relative=(x,y)`。
