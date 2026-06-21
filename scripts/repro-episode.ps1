param(
  [string]$ProcessName = "codeArts-agent",
  [int]$Loops = 10,
  [int]$WarmupSeconds = 60,
  [int]$CoverSeconds = 180,
  [int]$MemoryPressureMb = 0,
  [int]$MemoryPressureSeconds = 60,
  [switch]$TrimWorkingSet,
  [switch]$UseMinimize,
  [ValidateSet("maximize", "restore")]
  [string]$RestoreMode = "maximize",
  [string]$AgentPrompt = "",
  [string]$AgentPromptFile = "",
  [string]$AgentPromptDir = "",
  [string]$AgentFocusKeys = "",
  [string]$AgentClickSequence = "",
  [int]$AgentClickX = -1,
  [int]$AgentClickY = -1,
  [int]$AgentNewChatClickX = -1,
  [int]$AgentNewChatClickY = -1,
  [int]$AgentFirstInputClickX = -1,
  [int]$AgentFirstInputClickY = -1,
  [int]$AgentFollowupInputClickX = -1,
  [int]$AgentFollowupInputClickY = -1,
  [string]$AgentSubmitKeys = "{ENTER}",
  [int]$AgentPasteRetries = 1,
  [switch]$MaximizeBeforeAgentInput,
  [switch]$PromptBeforeEachLoop,
  [int]$AgentRunSeconds = 60,
  [int]$AgentCooldownSeconds = 0,
  [string]$OpenUrlDuringHidden = "",
  [int]$OpenUrlDelaySeconds = 10,
  [switch]$OpenLocalStressPage,
  [string]$LogDir = ".\.black-screen-repro\episodes"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class EpisodeWin32 {
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

$SW_MINIMIZE = 6
$SW_RESTORE = 9
$SW_MAXIMIZE = 3

function Get-TargetWindow {
  $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 }

  if (-not $processes) {
    throw "No process named '$ProcessName' with a main window was found."
  }

  return $processes | Select-Object -First 1
}

if (-not (Test-Path -LiteralPath $LogDir)) {
  New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Invoke-AgentPrompt {
  param(
    [string]$PromptFileOverride = "",
    [int]$Attempt = 1
  )

  if (-not $AgentPrompt -and -not $AgentPromptFile -and -not $PromptFileOverride) {
    return
  }

  $clickSequenceForAttempt = $AgentClickSequence
  $clickXForAttempt = $AgentClickX
  $clickYForAttempt = $AgentClickY

  if ($AgentNewChatClickX -ge 0 -and $AgentNewChatClickY -ge 0) {
    if ($Attempt -eq 1 -and $AgentFirstInputClickX -ge 0 -and $AgentFirstInputClickY -ge 0) {
      $clickSequenceForAttempt = "$AgentNewChatClickX,$AgentNewChatClickY;$AgentFirstInputClickX,$AgentFirstInputClickY"
      $clickXForAttempt = -1
      $clickYForAttempt = -1
    } elseif ($Attempt -gt 1 -and $AgentFollowupInputClickX -ge 0 -and $AgentFollowupInputClickY -ge 0) {
      $clickSequenceForAttempt = "$AgentNewChatClickX,$AgentNewChatClickY;$AgentFollowupInputClickX,$AgentFollowupInputClickY"
      $clickXForAttempt = -1
      $clickYForAttempt = -1
    }
  }

  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", (Join-Path $PSScriptRoot "send-agent-prompt.ps1"),
    "-ProcessName", $ProcessName,
    "-ClickX", $clickXForAttempt,
    "-ClickY", $clickYForAttempt,
    "-PasteRetries", $AgentPasteRetries
  )

  if ($AgentFocusKeys) {
    $args += @("-FocusKeys", $AgentFocusKeys)
  }

  if ($clickSequenceForAttempt) {
    $args += @("-ClickSequence", $clickSequenceForAttempt)
  }

  if ($AgentSubmitKeys) {
    $args += @("-SubmitKeys", $AgentSubmitKeys)
  }

  if ($MaximizeBeforeAgentInput) {
    $args += "-MaximizeBeforeInput"
  }

  if ($PromptFileOverride) {
    $args += @("-PromptFile", $PromptFileOverride)
  } elseif ($AgentPromptFile) {
    $args += @("-PromptFile", $AgentPromptFile)
  } else {
    $args += @("-Prompt", $AgentPrompt)
  }

  powershell @args
}

function Get-PromptFileForLoop {
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

function Start-LocalStressPage {
  $path = Join-Path (Split-Path -Parent $PSScriptRoot) "web-stress\stress.html"
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Local stress page not found: $path"
  }

  Start-Process $path
}

if ($AgentPrompt -or $AgentPromptFile -or $AgentPromptDir) {
  Write-Host "Sending initial agent prompt"
    Invoke-AgentPrompt -PromptFileOverride (Get-PromptFileForLoop -Index 1) -Attempt 1
}

Write-Host "Warmup for $WarmupSeconds seconds. Start the real agent/plugin workload now if needed."
Start-Sleep -Seconds $WarmupSeconds

for ($i = 1; $i -le $Loops; $i++) {
  $episode = "episode_{0:000}_{1}" -f $i, (Get-Date -Format "yyyyMMdd_HHmmss")
  $episodeDir = Join-Path $LogDir $episode
  New-Item -ItemType Directory -Path $episodeDir -Force | Out-Null

  Write-Host "=== $episode ==="
  $target = Get-TargetWindow
  $hwnd = $target.MainWindowHandle

  if ($PromptBeforeEachLoop) {
    Write-Host "Sending per-loop agent prompt"
    Invoke-AgentPrompt -PromptFileOverride (Get-PromptFileForLoop -Index $i) -Attempt 1
    Write-Host "Agent active phase: $AgentRunSeconds seconds"
    Start-Sleep -Seconds $AgentRunSeconds
  }

  if ($AgentCooldownSeconds -gt 0) {
    Write-Host "Agent cooldown/finished phase: $AgentCooldownSeconds seconds"
    Start-Sleep -Seconds $AgentCooldownSeconds
  }

  if ($UseMinimize) {
    Write-Host "Minimizing target"
    [void][EpisodeWin32]::ShowWindow($hwnd, $SW_MINIMIZE)
    Start-Sleep -Seconds $CoverSeconds
  } else {
    Write-Host "Covering target for $CoverSeconds seconds"
    $cover = Start-Process powershell -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", (Join-Path $PSScriptRoot "cover-window.ps1"),
      "-ProcessName", $ProcessName,
      "-Seconds", $CoverSeconds
    ) -PassThru
    Start-Sleep -Seconds 5
  }

  if ($OpenUrlDuringHidden) {
    Write-Host "Opening URL during hidden/covered period: $OpenUrlDuringHidden"
    Start-Process $OpenUrlDuringHidden
    Start-Sleep -Seconds $OpenUrlDelaySeconds
  }

  if ($OpenLocalStressPage) {
    Write-Host "Opening local browser stress page during hidden/covered period"
    Start-LocalStressPage
    Start-Sleep -Seconds $OpenUrlDelaySeconds
  }

  if ($TrimWorkingSet) {
    Write-Host "Trimming working set"
    powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "trim-working-set.ps1") -ProcessName $ProcessName |
      Tee-Object -FilePath (Join-Path $episodeDir "trim-working-set.txt")
  }

  if ($MemoryPressureMb -gt 0) {
    Write-Host "Starting memory pressure ${MemoryPressureMb}MB"
    $mp = Start-Process powershell -ArgumentList @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", (Join-Path $PSScriptRoot "memory-pressure.ps1"),
      "-Megabytes", $MemoryPressureMb,
      "-HoldSeconds", $MemoryPressureSeconds
    ) -PassThru
    $mp.WaitForExit()
  }

  if (-not $UseMinimize -and $cover) {
    $cover.WaitForExit()
  }

  $target = Get-TargetWindow
  Write-Host "Restoring target"
  if ($RestoreMode -eq "maximize") {
    [void][EpisodeWin32]::ShowWindow($target.MainWindowHandle, $SW_MAXIMIZE)
  } else {
    [void][EpisodeWin32]::ShowWindow($target.MainWindowHandle, $SW_RESTORE)
  }
  [void][EpisodeWin32]::SetForegroundWindow($target.MainWindowHandle)
  Start-Sleep -Seconds 3

  $shot = Join-Path $episodeDir "window-shot.png"
  $json = powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-window-black.ps1") -ProcessName $ProcessName -OutPath $shot
  $json | Tee-Object -FilePath (Join-Path $episodeDir "black-check.json")
  $result = $json | ConvertFrom-Json

  if ($result.isBlack) {
    Write-Host "Black screen suspected. Episode artifacts: $episodeDir"
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
      Select-Object Id,ProcessName,MainWindowTitle,Path,StartTime |
      ConvertTo-Json |
      Out-File -LiteralPath (Join-Path $episodeDir "processes.json") -Encoding utf8
    exit 2
  }

  Write-Host "No black screen detected in $episode"
}

Write-Host "Done. No black screen detected."
