param(
  [string]$ProcessName = "Code",
  [string]$OutPath = ".\.black-screen-repro\window-shot.png",
  [double]$Threshold = 0.80
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class ShotWin32 {
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

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
[void][ShotWin32]::SetForegroundWindow($target.MainWindowHandle)
Start-Sleep -Milliseconds 500

$rect = New-Object ShotWin32+RECT
[void][ShotWin32]::GetWindowRect($target.MainWindowHandle, [ref]$rect)
$width = [Math]::Max(1, $rect.Right - $rect.Left)
$height = [Math]::Max(1, $rect.Bottom - $rect.Top)

$dir = Split-Path -Parent $OutPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$bitmap = New-Object System.Drawing.Bitmap($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
$graphics.Dispose()
$bitmap.Save((Resolve-Path -LiteralPath $dir).Path + "\" + (Split-Path -Leaf $OutPath), [System.Drawing.Imaging.ImageFormat]::Png)

$sampleStep = [Math]::Max(1, [int]([Math]::Sqrt(($width * $height) / 20000)))
$black = 0
$total = 0

for ($y = 0; $y -lt $height; $y += $sampleStep) {
  for ($x = 0; $x -lt $width; $x += $sampleStep) {
    $pixel = $bitmap.GetPixel($x, $y)
    $isBlack = ($pixel.R -lt 18 -and $pixel.G -lt 18 -and $pixel.B -lt 18)
    if ($isBlack) { $black++ }
    $total++
  }
}

$bitmap.Dispose()
$ratio = if ($total -gt 0) { $black / $total } else { 0 }
$result = [pscustomobject]@{
  processName = $target.ProcessName
  pid = $target.Id
  width = $width
  height = $height
  blackRatio = [Math]::Round($ratio, 4)
  threshold = $Threshold
  isBlack = ($ratio -ge $Threshold)
  screenshot = (Resolve-Path -LiteralPath $OutPath -ErrorAction SilentlyContinue).Path
  time = (Get-Date).ToString("o")
}

$result | ConvertTo-Json -Compress
if ($result.isBlack) {
  exit 2
}
