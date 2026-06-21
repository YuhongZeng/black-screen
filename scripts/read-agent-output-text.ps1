param(
  [string]$ProcessName = "codeArts-agent",
  [int]$StartX,
  [int]$StartY,
  [int]$EndX,
  [int]$EndY,
  [string]$DetectPrefix = "Cannot connect to API",
  [int]$DelayMs = 300,
  [int]$DragSteps = 20,
  [string]$OutFile = ""
)

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class AgentReadTextWin32 {
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);

  [DllImport("user32.dll")]
  public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }
}
"@

$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004

function Get-TargetWindow {
  $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 }

  if (-not $processes) {
    throw "No process named '$ProcessName' with a main window was found."
  }

  return $processes | Sort-Object StartTime | Select-Object -First 1
}

function Convert-ToScreenPoint {
  param(
    [IntPtr]$Hwnd,
    [int]$RelativeX,
    [int]$RelativeY
  )

  $rect = New-Object AgentReadTextWin32+RECT
  [void][AgentReadTextWin32]::GetWindowRect($Hwnd, [ref]$rect)
  return [pscustomobject]@{
    X = $rect.Left + $RelativeX
    Y = $rect.Top + $RelativeY
  }
}

function Invoke-DragSelect {
  param(
    [int]$FromX,
    [int]$FromY,
    [int]$ToX,
    [int]$ToY
  )

  [void][AgentReadTextWin32]::SetCursorPos($FromX, $FromY)
  Start-Sleep -Milliseconds 100
  [AgentReadTextWin32]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 100

  $steps = [Math]::Max(1, $DragSteps)
  for ($i = 1; $i -le $steps; $i++) {
    $x = [int]($FromX + (($ToX - $FromX) * $i / $steps))
    $y = [int]($FromY + (($ToY - $FromY) * $i / $steps))
    [void][AgentReadTextWin32]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 20
  }

  Start-Sleep -Milliseconds 100
  [AgentReadTextWin32]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
}

$target = Get-TargetWindow
[void][AgentReadTextWin32]::SetForegroundWindow($target.MainWindowHandle)
Start-Sleep -Milliseconds $DelayMs

$start = Convert-ToScreenPoint -Hwnd $target.MainWindowHandle -RelativeX $StartX -RelativeY $StartY
$end = Convert-ToScreenPoint -Hwnd $target.MainWindowHandle -RelativeX $EndX -RelativeY $EndY

[System.Windows.Forms.Clipboard]::Clear()
Start-Sleep -Milliseconds 100
Invoke-DragSelect -FromX $start.X -FromY $start.Y -ToX $end.X -ToY $end.Y
Start-Sleep -Milliseconds $DelayMs
[System.Windows.Forms.SendKeys]::SendWait("^c")
Start-Sleep -Milliseconds $DelayMs

$text = [System.Windows.Forms.Clipboard]::GetText()
$normalized = if ($text) { $text.TrimStart() } else { "" }
$isMatch = $normalized.StartsWith($DetectPrefix, [StringComparison]::OrdinalIgnoreCase)

$result = [pscustomobject]@{
  time = (Get-Date).ToString("o")
  processName = $target.ProcessName
  pid = $target.Id
  start = "$StartX,$StartY"
  end = "$EndX,$EndY"
  detectPrefix = $DetectPrefix
  isMatch = $isMatch
  textLength = $text.Length
  firstLine = (($normalized -split "`r?`n") | Select-Object -First 1)
  text = $text
}

if ($OutFile) {
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $result | ConvertTo-Json -Depth 3 | Out-File -LiteralPath $OutFile -Encoding utf8
}

$result | ConvertTo-Json -Compress
if ($isMatch) {
  exit 2
}
