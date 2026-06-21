param(
  [int]$Megabytes = 2048,
  [int]$HoldSeconds = 60,
  [int]$ChunkMegabytes = 64
)

$chunks = New-Object System.Collections.Generic.List[byte[]]
$allocated = 0

try {
  while ($allocated -lt $Megabytes) {
    $size = [Math]::Min($ChunkMegabytes, $Megabytes - $allocated)
    $buffer = New-Object byte[] ($size * 1MB)
    for ($i = 0; $i -lt $buffer.Length; $i += 4096) {
      $buffer[$i] = [byte]($allocated % 251)
    }
    $chunks.Add($buffer)
    $allocated += $size
    Write-Host "Allocated ${allocated}MB / ${Megabytes}MB"
    Start-Sleep -Milliseconds 100
  }

  Write-Host "Holding memory pressure for $HoldSeconds seconds"
  Start-Sleep -Seconds $HoldSeconds
} finally {
  $chunks.Clear()
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
  Write-Host "Released memory pressure"
}
