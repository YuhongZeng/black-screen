param(
  [string]$ProcessName = "Code",
  [int]$Width = 620,
  [int]$Height = 420,
  [int]$OffsetX = 120,
  [int]$OffsetY = 120,
  [int]$Seconds = 300,
  [string]$Title = "Black Screen Repro Cover"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CoverWin32 {
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

  return $processes | Select-Object -First 1
}

$target = Get-TargetWindow
$rect = New-Object CoverWin32+RECT
[void][CoverWin32]::GetWindowRect($target.MainWindowHandle, [ref]$rect)

$form = New-Object System.Windows.Forms.Form
$form.Text = $Title
$form.StartPosition = "Manual"
$form.Size = New-Object System.Drawing.Size($Width, $Height)
$form.Location = New-Object System.Drawing.Point(($rect.Left + $OffsetX), ($rect.Top + $OffsetY))
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)

$label = New-Object System.Windows.Forms.Label
$label.Dock = "Fill"
$label.ForeColor = [System.Drawing.Color]::White
$label.BackColor = $form.BackColor
$label.Font = New-Object System.Drawing.Font("Consolas", 11)
$label.TextAlign = "MiddleCenter"
$label.Text = "Covering target window.`r`nDo not interact with IDE.`r`nSeconds: $Seconds"
$form.Controls.Add($label)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$remaining = $Seconds
$timer.Add_Tick({
  $script:remaining -= 1
  $label.Text = "Covering target window.`r`nDo not interact with IDE.`r`nSeconds: $script:remaining"
  if ($script:remaining -le 0) {
    $timer.Stop()
    $form.Close()
  }
})

$form.Add_Shown({ $timer.Start() })
[void]$form.ShowDialog()
