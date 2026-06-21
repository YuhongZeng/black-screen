param(
  [string]$ProcessName = "Code",
  [string]$Prompt = "",
  [string]$PromptFile = "",
  [string]$FocusKeys = "",
  [int]$ClickX = -1,
  [int]$ClickY = -1,
  [string]$SubmitKeys = "{ENTER}",
  [int]$DelayMs = 300
)

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class AgentPromptWin32 {
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

  return $processes | Select-Object -First 1
}

if ($PromptFile) {
  $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}

if (-not $Prompt) {
  throw "Prompt is empty. Provide -Prompt or -PromptFile."
}

$target = Get-TargetWindow
[void][AgentPromptWin32]::SetForegroundWindow($target.MainWindowHandle)
Start-Sleep -Milliseconds $DelayMs

if ($FocusKeys) {
  [System.Windows.Forms.SendKeys]::SendWait($FocusKeys)
  Start-Sleep -Milliseconds $DelayMs
}

if ($ClickX -ge 0 -and $ClickY -ge 0) {
  $rect = New-Object AgentPromptWin32+RECT
  [void][AgentPromptWin32]::GetWindowRect($target.MainWindowHandle, [ref]$rect)
  $screenX = $rect.Left + $ClickX
  $screenY = $rect.Top + $ClickY
  [void][AgentPromptWin32]::SetCursorPos($screenX, $screenY)
  Start-Sleep -Milliseconds 100
  [AgentPromptWin32]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [AgentPromptWin32]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds $DelayMs
}

[System.Windows.Forms.Clipboard]::SetText($Prompt)
Start-Sleep -Milliseconds 100
[System.Windows.Forms.SendKeys]::SendWait("^v")
Start-Sleep -Milliseconds $DelayMs

if ($SubmitKeys) {
  [System.Windows.Forms.SendKeys]::SendWait($SubmitKeys)
}

Write-Host "Prompt sent to $($target.ProcessName) pid=$($target.Id)"
