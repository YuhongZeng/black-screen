param(
  [string]$ProcessName = "Code",
  [int]$Loops = 300,
  [int]$HiddenMs = 1500,
  [int]$VisibleMs = 1200
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32WindowLoop {
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool IsWindow(IntPtr hWnd);
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

$target = Get-TargetWindow
$hwnd = $target.MainWindowHandle
Write-Host "Target process: $($target.ProcessName) pid=$($target.Id) hwnd=0x$($hwnd.ToString('X'))"
Write-Host "Loops=$Loops HiddenMs=$HiddenMs VisibleMs=$VisibleMs"

for ($i = 1; $i -le $Loops; $i++) {
  if (-not [Win32WindowLoop]::IsWindow($hwnd)) {
    $target = Get-TargetWindow
    $hwnd = $target.MainWindowHandle
    Write-Host "Reacquired hwnd=0x$($hwnd.ToString('X'))"
  }

  [void][Win32WindowLoop]::ShowWindow($hwnd, $SW_MINIMIZE)
  Start-Sleep -Milliseconds $HiddenMs
  [void][Win32WindowLoop]::ShowWindow($hwnd, $SW_RESTORE)
  [void][Win32WindowLoop]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds $VisibleMs

  if (($i % 25) -eq 0) {
    Write-Host "Completed $i loops"
  }
}

Write-Host "Done."
