param(
  [string]$ProcessName = "codeArts-agent",
  [int]$RegionX = 0,
  [int]$RegionY = 0,
  [int]$RegionWidth = 900,
  [int]$RegionHeight = 700,
  [int]$MaxSeconds = 180,
  [int]$QuietSeconds = 20,
  [int]$IntervalSeconds = 2,
  [double]$ChangeThreshold = 0.002,
  [string]$LogPath = ""
)

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class AgentStableWin32 {
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }
}
"@

function Get-TargetWindow {
  $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 }

  if (-not $processes) {
    throw "No process named '$ProcessName' with a main window was found."
  }

  return $processes | Sort-Object StartTime | Select-Object -First 1
}

function Capture-Region {
  param([IntPtr]$Hwnd)

  $rect = New-Object AgentStableWin32+RECT
  [void][AgentStableWin32]::GetWindowRect($Hwnd, [ref]$rect)

  $x = $rect.Left + $RegionX
  $y = $rect.Top + $RegionY
  $bitmap = New-Object System.Drawing.Bitmap($RegionWidth, $RegionHeight)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.CopyFromScreen($x, $y, 0, 0, $bitmap.Size)
  $graphics.Dispose()
  return $bitmap
}

function Compare-Bitmaps {
  param(
    [System.Drawing.Bitmap]$A,
    [System.Drawing.Bitmap]$B
  )

  if (-not $A -or -not $B) {
    return 1.0
  }

  $width = [Math]::Min($A.Width, $B.Width)
  $height = [Math]::Min($A.Height, $B.Height)
  $sampleStep = [Math]::Max(1, [int]([Math]::Sqrt(($width * $height) / 12000)))
  $changed = 0
  $total = 0

  for ($yy = 0; $yy -lt $height; $yy += $sampleStep) {
    for ($xx = 0; $xx -lt $width; $xx += $sampleStep) {
      $pa = $A.GetPixel($xx, $yy)
      $pb = $B.GetPixel($xx, $yy)
      $delta = [Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B)
      if ($delta -gt 18) {
        $changed++
      }
      $total++
    }
  }

  if ($total -eq 0) {
    return 1.0
  }

  return $changed / $total
}

function Write-Log {
  param([hashtable]$Data)
  $record = [ordered]@{
    time = (Get-Date).ToString("o")
  }
  foreach ($key in $Data.Keys) {
    $record[$key] = $Data[$key]
  }
  $json = $record | ConvertTo-Json -Compress
  if ($LogPath) {
    Add-Content -LiteralPath $LogPath -Value $json -Encoding utf8
  }
  Write-Host $json
}

$target = Get-TargetWindow
$previous = $null
$stableFor = 0
$elapsed = 0
$lastChangeRatio = 1.0

try {
  while ($elapsed -le $MaxSeconds) {
    $current = Capture-Region -Hwnd $target.MainWindowHandle
    $changeRatio = Compare-Bitmaps -A $previous -B $current
    $lastChangeRatio = $changeRatio

    if ($changeRatio -le $ChangeThreshold) {
      $stableFor += $IntervalSeconds
    } else {
      $stableFor = 0
    }

    Write-Log @{
      elapsedSec = $elapsed
      stableForSec = $stableFor
      changeRatio = [Math]::Round($changeRatio, 6)
      threshold = $ChangeThreshold
      region = "$RegionX,$RegionY,$RegionWidth,$RegionHeight"
    }

    if ($stableFor -ge $QuietSeconds) {
      Write-Log @{
        result = "stable"
        elapsedSec = $elapsed
        stableForSec = $stableFor
        changeRatio = [Math]::Round($changeRatio, 6)
      }
      exit 0
    }

    if ($previous) {
      $previous.Dispose()
    }
    $previous = $current
    Start-Sleep -Seconds $IntervalSeconds
    $elapsed += $IntervalSeconds
  }

  Write-Log @{
    result = "timeout"
    elapsedSec = $elapsed
    stableForSec = $stableFor
    changeRatio = [Math]::Round($lastChangeRatio, 6)
  }
  exit 1
} finally {
  if ($previous) {
    $previous.Dispose()
  }
}
