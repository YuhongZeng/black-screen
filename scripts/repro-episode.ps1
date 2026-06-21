param(
  [string]$ProcessName = "Code",
  [int]$Loops = 10,
  [int]$WarmupSeconds = 60,
  [int]$CoverSeconds = 180,
  [int]$MemoryPressureMb = 0,
  [int]$MemoryPressureSeconds = 60,
  [switch]$TrimWorkingSet,
  [switch]$UseMinimize,
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

Write-Host "Warmup for $WarmupSeconds seconds. Start the real agent/plugin workload now if needed."
Start-Sleep -Seconds $WarmupSeconds

for ($i = 1; $i -le $Loops; $i++) {
  $episode = "episode_{0:000}_{1}" -f $i, (Get-Date -Format "yyyyMMdd_HHmmss")
  $episodeDir = Join-Path $LogDir $episode
  New-Item -ItemType Directory -Path $episodeDir -Force | Out-Null

  Write-Host "=== $episode ==="
  $target = Get-TargetWindow
  $hwnd = $target.MainWindowHandle

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
  [void][EpisodeWin32]::ShowWindow($target.MainWindowHandle, $SW_RESTORE)
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
