param(
  [string]$ProcessName = "codeArts-agent",
  [string]$Prompt = "",
  [string]$PromptFile = "",
  [string]$FocusKeys = "",
  [string]$ClickSequence = "",
  [int]$ClickX = -1,
  [int]$ClickY = -1,
  [string]$SubmitKeys = "{ENTER}",
  [int]$DelayMs = 300,
  [int]$PasteRetries = 1,
  [switch]$MaximizeBeforeInput,
  [switch]$UseCurrentForeground,
  [int]$CountdownSeconds = 0
)

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class AgentPromptWin32 {
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

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

$SW_MAXIMIZE = 3
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

function Invoke-RelativeClick {
  param(
    [IntPtr]$Hwnd,
    [int]$X,
    [int]$Y
  )

  $rect = New-Object AgentPromptWin32+RECT
  [void][AgentPromptWin32]::GetWindowRect($Hwnd, [ref]$rect)
  $screenX = $rect.Left + $X
  $screenY = $rect.Top + $Y
  [void][AgentPromptWin32]::SetCursorPos($screenX, $screenY)
  Start-Sleep -Milliseconds 100
  [AgentPromptWin32]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [AgentPromptWin32]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds $DelayMs
}

function Invoke-ClickSequence {
  param(
    [IntPtr]$Hwnd,
    [string]$Sequence
  )

  if (-not $Sequence) {
    return
  }

  $items = $Sequence.Split(';') | Where-Object { $_.Trim() }
  foreach ($item in $items) {
    $parts = $item.Trim().Split(',')
    if ($parts.Count -ne 2) {
      throw "Invalid ClickSequence item '$item'. Use 'x,y;x,y'."
    }

    Invoke-RelativeClick -Hwnd $Hwnd -X ([int]$parts[0]) -Y ([int]$parts[1])
  }
}

if ($PromptFile) {
  $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}

if (-not $Prompt) {
  throw "Prompt is empty. Provide -Prompt or -PromptFile."
}

$target = Get-TargetWindow

if ($CountdownSeconds -gt 0) {
  Write-Host "Countdown mode: focus the Agent input box now. Pasting in $CountdownSeconds seconds..."
  for ($i = $CountdownSeconds; $i -gt 0; $i--) {
    Write-Host "$i..."
    Start-Sleep -Seconds 1
  }
}

if ($MaximizeBeforeInput -and -not $UseCurrentForeground) {
  [void][AgentPromptWin32]::ShowWindow($target.MainWindowHandle, $SW_MAXIMIZE)
  Start-Sleep -Milliseconds $DelayMs
}

if (-not $UseCurrentForeground) {
  [void][AgentPromptWin32]::SetForegroundWindow($target.MainWindowHandle)
  Start-Sleep -Milliseconds $DelayMs
}

if ($FocusKeys -and -not $UseCurrentForeground) {
  [System.Windows.Forms.SendKeys]::SendWait($FocusKeys)
  Start-Sleep -Milliseconds $DelayMs
}

if (-not $UseCurrentForeground) {
  Invoke-ClickSequence -Hwnd $target.MainWindowHandle -Sequence $ClickSequence

  if ($ClickX -ge 0 -and $ClickY -ge 0) {
    Invoke-RelativeClick -Hwnd $target.MainWindowHandle -X $ClickX -Y $ClickY
  }
}

[System.Windows.Forms.Clipboard]::SetText($Prompt)
Start-Sleep -Milliseconds 100

for ($i = 0; $i -lt [Math]::Max(1, $PasteRetries); $i++) {
  [System.Windows.Forms.SendKeys]::SendWait("^v")
  Start-Sleep -Milliseconds $DelayMs
}

if ($SubmitKeys) {
  [System.Windows.Forms.SendKeys]::SendWait($SubmitKeys)
}

Write-Host "Prompt sent to $($target.ProcessName) pid=$($target.Id)"
