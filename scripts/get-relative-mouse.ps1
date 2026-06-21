param(
  [string]$ProcessName = "codeArts-agent",
  [int]$Samples = 1,
  [int]$IntervalMs = 1000
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class RelativeMouseWin32 {
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [DllImport("user32.dll")]
  public static extern bool GetCursorPos(out POINT lpPoint);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
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

$target = Get-TargetWindow
$rect = New-Object RelativeMouseWin32+RECT
[void][RelativeMouseWin32]::GetWindowRect($target.MainWindowHandle, [ref]$rect)

Write-Host "Target: $($target.ProcessName) pid=$($target.Id) hwnd=0x$($target.MainWindowHandle.ToString('X'))"
Write-Host "Window rect: left=$($rect.Left) top=$($rect.Top) right=$($rect.Right) bottom=$($rect.Bottom)"
Write-Host "Move mouse to the target UI point. Reporting relative x,y..."

for ($i = 1; $i -le $Samples; $i++) {
  $point = New-Object RelativeMouseWin32+POINT
  [void][RelativeMouseWin32]::GetCursorPos([ref]$point)
  $relativeX = $point.X - $rect.Left
  $relativeY = $point.Y - $rect.Top
  Write-Host ("sample={0} screen=({1},{2}) relative=({3},{4})" -f $i, $point.X, $point.Y, $relativeX, $relativeY)
  if ($i -lt $Samples) {
    Start-Sleep -Milliseconds $IntervalMs
  }
}
