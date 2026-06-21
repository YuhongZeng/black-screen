param(
  [string]$ProcessName = "Code",
  [ValidateSet("cover", "minimize")]
  [string]$WindowMode = "cover",
  [ValidateSet("maximize", "restore")]
  [string]$RestoreMode = "maximize",
  [int]$Episodes = 20,
  [int]$WarmupSeconds = 60,
  [int]$HiddenSeconds = 180,
  [int]$PostRestoreObserveSeconds = 600,
  [int]$PostRestoreCheckIntervalSeconds = 5,
  [string]$AgentPrompt = "",
  [string]$AgentPromptFile = "",
  [string]$AgentPromptDir = "",
  [string]$AgentFocusKeys = "",
  [int]$AgentClickX = -1,
  [int]$AgentClickY = -1,
  [string]$AgentSubmitKeys = "{ENTER}",
  [int]$AgentRunSeconds = 90,
  [int]$AgentCooldownSeconds = 120,
  [switch]$PromptEachEpisode,
  [switch]$TrimWorkingSet,
  [int]$MemoryPressureMb = 0,
  [int]$MemoryPressureSeconds = 60,
  [switch]$OpenLocalStressPage,
  [string]$OpenUrlDuringHidden = "",
  [int]$OpenUrlDelaySeconds = 10,
  [double]$BlackThreshold = 0.80,
  [switch]$NoKeepDisplayOn,
  [string]$LogDir = ".\.black-screen-repro\stable-runs"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class StableRunnerWin32 {
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("kernel32.dll")]
  public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

$SW_MINIMIZE = 6
$SW_RESTORE = 9
$SW_MAXIMIZE = 3
$ES_CONTINUOUS = 0x80000000
$ES_SYSTEM_REQUIRED = 0x00000001
$ES_DISPLAY_REQUIRED = 0x00000002

function Get-TargetWindow {
  $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 }

  if (-not $processes) {
    throw "No process named '$ProcessName' with a main window was found."
  }

  return $processes | Sort-Object StartTime | Select-Object -First 1
}

function Write-Event {
  param(
    [string]$Episode,
    [string]$Step,
    [hashtable]$Data = @{}
  )

  $record = [ordered]@{
    time = (Get-Date).ToString("o")
    episode = $Episode
    step = $Step
  }

  foreach ($key in $Data.Keys) {
    $record[$key] = $Data[$key]
  }

  $json = ($record | ConvertTo-Json -Compress)
  Add-Content -LiteralPath $script:EventLog -Value $json -Encoding utf8
  Write-Host $json
}

function Get-PromptFileForEpisode {
  param([int]$Index)

  if (-not $AgentPromptDir) {
    return ""
  }

  $files = Get-ChildItem -LiteralPath $AgentPromptDir -File -Filter *.txt | Sort-Object Name
  if (-not $files) {
    throw "No .txt prompt files found in '$AgentPromptDir'."
  }

  return $files[($Index - 1) % $files.Count].FullName
}

function Invoke-AgentPrompt {
  param(
    [string]$PromptFileOverride = ""
  )

  if (-not $AgentPrompt -and -not $AgentPromptFile -and -not $PromptFileOverride) {
    return
  }

  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "send-agent-prompt.ps1"),
    "-ProcessName", $ProcessName,
    "-FocusKeys", $AgentFocusKeys,
    "-ClickX", $AgentClickX,
    "-ClickY", $AgentClickY,
    "-SubmitKeys", $AgentSubmitKeys
  )

  if ($PromptFileOverride) {
    $args += @("-PromptFile", $PromptFileOverride)
  } elseif ($AgentPromptFile) {
    $args += @("-PromptFile", $AgentPromptFile)
  } else {
    $args += @("-Prompt", $AgentPrompt)
  }

  powershell @args
}

function Start-LocalStressPage {
  $path = Join-Path (Split-Path -Parent $PSScriptRoot) "web-stress\stress.html"
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Local stress page not found: $path"
  }

  Start-Process $path
}

function Start-HiddenState {
  param(
    [System.Diagnostics.Process]$Target,
    [string]$EpisodeDir
  )

  if ($WindowMode -eq "minimize") {
    [void][StableRunnerWin32]::ShowWindow($Target.MainWindowHandle, $SW_MINIMIZE)
    return $null
  }

  return Start-Process powershell -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "cover-window.ps1"),
    "-ProcessName", $ProcessName,
    "-Seconds", $HiddenSeconds
  ) -PassThru
}

function Restore-TargetWindow {
  $target = Get-TargetWindow
  if ($RestoreMode -eq "maximize") {
    [void][StableRunnerWin32]::ShowWindow($target.MainWindowHandle, $SW_MAXIMIZE)
  } else {
    [void][StableRunnerWin32]::ShowWindow($target.MainWindowHandle, $SW_RESTORE)
  }
  [void][StableRunnerWin32]::SetForegroundWindow($target.MainWindowHandle)
}

function Invoke-BlackCheck {
  param(
    [string]$EpisodeDir,
    [int]$Index
  )

  $shot = Join-Path $EpisodeDir ("window-shot-{0:0000}.png" -f $Index)
  $json = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-window-black.ps1") `
    -ProcessName $ProcessName `
    -OutPath $shot `
    -Threshold $BlackThreshold

  $checkPath = Join-Path $EpisodeDir ("black-check-{0:0000}.json" -f $Index)
  $json | Out-File -LiteralPath $checkPath -Encoding utf8
  return ($json | ConvertFrom-Json)
}

function Save-ProcessSnapshot {
  param([string]$EpisodeDir)

  Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Select-Object Id,ProcessName,MainWindowTitle,Path,StartTime,WorkingSet64,PrivateMemorySize64 |
    ConvertTo-Json |
    Out-File -LiteralPath (Join-Path $EpisodeDir "processes.json") -Encoding utf8
}

if (-not (Test-Path -LiteralPath $LogDir)) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$runId = "run_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")
$runDir = Join-Path $LogDir $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$script:EventLog = Join-Path $runDir "events.ndjson"
New-Item -ItemType File -Path $script:EventLog -Force | Out-Null

if (-not $NoKeepDisplayOn) {
  [void][StableRunnerWin32]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_DISPLAY_REQUIRED)
  Write-Event -Episode "run" -Step "keep_display_on.enabled"
} else {
  Write-Event -Episode "run" -Step "keep_display_on.disabled"
}

try {
  Write-Event -Episode "run" -Step "config" -Data @{
    processName = $ProcessName
    windowMode = $WindowMode
    restoreMode = $RestoreMode
    episodes = $Episodes
    hiddenSeconds = $HiddenSeconds
    observeSeconds = $PostRestoreObserveSeconds
    observeIntervalSeconds = $PostRestoreCheckIntervalSeconds
    trimWorkingSet = [bool]$TrimWorkingSet
    memoryPressureMb = $MemoryPressureMb
    openLocalStressPage = [bool]$OpenLocalStressPage
    openUrlDuringHidden = $OpenUrlDuringHidden
  }

  if ($AgentPrompt -or $AgentPromptFile -or $AgentPromptDir) {
    Write-Event -Episode "run" -Step "agent.initial_prompt.begin"
    Invoke-AgentPrompt -PromptFileOverride (Get-PromptFileForEpisode -Index 1)
    Write-Event -Episode "run" -Step "agent.initial_prompt.end"
  }

  Write-Event -Episode "run" -Step "warmup.begin" -Data @{ seconds = $WarmupSeconds }
  Start-Sleep -Seconds $WarmupSeconds
  Write-Event -Episode "run" -Step "warmup.end"

  $hits = 0
  $summaries = New-Object System.Collections.Generic.List[object]

  for ($episodeIndex = 1; $episodeIndex -le $Episodes; $episodeIndex++) {
    $episode = "episode_{0:000}" -f $episodeIndex
    $episodeDir = Join-Path $runDir $episode
    New-Item -ItemType Directory -Path $episodeDir -Force | Out-Null

    Write-Event -Episode $episode -Step "begin"
    $target = Get-TargetWindow
    Write-Event -Episode $episode -Step "target" -Data @{
      pid = $target.Id
      hwnd = ("0x{0:X}" -f $target.MainWindowHandle.ToInt64())
      title = $target.MainWindowTitle
    }

    if ($PromptEachEpisode) {
      $promptFile = Get-PromptFileForEpisode -Index $episodeIndex
      Write-Event -Episode $episode -Step "agent.prompt.begin" -Data @{ promptFile = $promptFile }
      Invoke-AgentPrompt -PromptFileOverride $promptFile
      Write-Event -Episode $episode -Step "agent.prompt.end"

      if ($AgentRunSeconds -gt 0) {
        Write-Event -Episode $episode -Step "agent.active_wait.begin" -Data @{ seconds = $AgentRunSeconds }
        Start-Sleep -Seconds $AgentRunSeconds
        Write-Event -Episode $episode -Step "agent.active_wait.end"
      }
    }

    if ($AgentCooldownSeconds -gt 0) {
      Write-Event -Episode $episode -Step "agent.cooldown.begin" -Data @{ seconds = $AgentCooldownSeconds }
      Start-Sleep -Seconds $AgentCooldownSeconds
      Write-Event -Episode $episode -Step "agent.cooldown.end"
    }

    Write-Event -Episode $episode -Step "hidden.begin" -Data @{ mode = $WindowMode; seconds = $HiddenSeconds }
    $coverProcess = Start-HiddenState -Target $target -EpisodeDir $episodeDir
    Start-Sleep -Seconds 5

    if ($OpenUrlDuringHidden) {
      Write-Event -Episode $episode -Step "open_url.begin" -Data @{ url = $OpenUrlDuringHidden }
      Start-Process $OpenUrlDuringHidden
      Start-Sleep -Seconds $OpenUrlDelaySeconds
      Write-Event -Episode $episode -Step "open_url.end"
    }

    if ($OpenLocalStressPage) {
      Write-Event -Episode $episode -Step "open_local_stress_page.begin"
      Start-LocalStressPage
      Start-Sleep -Seconds $OpenUrlDelaySeconds
      Write-Event -Episode $episode -Step "open_local_stress_page.end"
    }

    if ($TrimWorkingSet) {
      Write-Event -Episode $episode -Step "trim.begin"
      powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "trim-working-set.ps1") -ProcessName $ProcessName |
        Tee-Object -FilePath (Join-Path $episodeDir "trim-working-set.txt")
      Write-Event -Episode $episode -Step "trim.end"
    }

    if ($MemoryPressureMb -gt 0) {
      Write-Event -Episode $episode -Step "memory_pressure.begin" -Data @{ mb = $MemoryPressureMb; seconds = $MemoryPressureSeconds }
      $mp = Start-Process powershell -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $PSScriptRoot "memory-pressure.ps1"),
        "-Megabytes", $MemoryPressureMb,
        "-HoldSeconds", $MemoryPressureSeconds
      ) -PassThru
      $mp.WaitForExit()
      Write-Event -Episode $episode -Step "memory_pressure.end" -Data @{ exitCode = $mp.ExitCode }
    }

    if ($WindowMode -eq "cover" -and $coverProcess) {
      $coverProcess.WaitForExit()
    } elseif ($WindowMode -eq "minimize") {
      $elapsedHidden = 5
      $remainingHidden = [Math]::Max(0, $HiddenSeconds - $elapsedHidden)
      if ($remainingHidden -gt 0) {
        Start-Sleep -Seconds $remainingHidden
      }
    }

    Write-Event -Episode $episode -Step "hidden.end"

    Write-Event -Episode $episode -Step "restore.begin"
    Restore-TargetWindow
    Start-Sleep -Seconds 2
    Write-Event -Episode $episode -Step "restore.end"

    $maxBlackRatio = 0.0
    $hit = $false
    $hitAfterRestoreSec = $null
    $checks = [Math]::Max(1, [int][Math]::Ceiling($PostRestoreObserveSeconds / [double]$PostRestoreCheckIntervalSeconds))

    Write-Event -Episode $episode -Step "observe.begin" -Data @{
      seconds = $PostRestoreObserveSeconds
      intervalSeconds = $PostRestoreCheckIntervalSeconds
      checks = $checks
    }

    for ($check = 1; $check -le $checks; $check++) {
      $secondsAfterRestore = ($check - 1) * $PostRestoreCheckIntervalSeconds
      if ($check -gt 1) {
        Start-Sleep -Seconds $PostRestoreCheckIntervalSeconds
      }

      $result = Invoke-BlackCheck -EpisodeDir $episodeDir -Index $check
      $maxBlackRatio = [Math]::Max($maxBlackRatio, [double]$result.blackRatio)
      Write-Event -Episode $episode -Step "observe.check" -Data @{
        check = $check
        secondsAfterRestore = $secondsAfterRestore
        blackRatio = [double]$result.blackRatio
        isBlack = [bool]$result.isBlack
        screenshot = $result.screenshot
      }

      if ($result.isBlack) {
        $hit = $true
        $hitAfterRestoreSec = $secondsAfterRestore
        $hits++
        Write-Event -Episode $episode -Step "hit" -Data @{
          secondsAfterRestore = $hitAfterRestoreSec
          blackRatio = [double]$result.blackRatio
        }
        Save-ProcessSnapshot -EpisodeDir $episodeDir
        break
      }
    }

    Write-Event -Episode $episode -Step "observe.end" -Data @{
      hit = $hit
      maxBlackRatio = $maxBlackRatio
      hitAfterRestoreSec = $hitAfterRestoreSec
    }

    $summaries.Add([pscustomobject]@{
      episode = $episode
      hit = $hit
      maxBlackRatio = [Math]::Round($maxBlackRatio, 4)
      hitAfterRestoreSec = $hitAfterRestoreSec
      directory = $episodeDir
    })

    $summaries | ConvertTo-Json |
      Out-File -LiteralPath (Join-Path $runDir "summary.json") -Encoding utf8

    if ($hit) {
      Write-Event -Episode "run" -Step "stop_on_hit" -Data @{ episode = $episode; hitCount = $hits }
      break
    }

    Write-Event -Episode $episode -Step "end" -Data @{ hit = $false; maxBlackRatio = $maxBlackRatio }
  }

  Write-Event -Episode "run" -Step "end" -Data @{
    hits = $hits
    runDir = (Resolve-Path -LiteralPath $runDir).Path
  }
  Write-Host "Run directory: $runDir"
} finally {
  if (-not $NoKeepDisplayOn) {
    [void][StableRunnerWin32]::SetThreadExecutionState($ES_CONTINUOUS)
  }
}
