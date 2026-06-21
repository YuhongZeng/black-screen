param(
  [string]$ProcessName = "Code"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class WorkingSetTrim {
  [DllImport("psapi.dll")]
  public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
"@

$targets = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
if (-not $targets) {
  throw "No process named '$ProcessName' was found."
}

foreach ($process in $targets) {
  try {
    $before = $process.WorkingSet64
    [void][WorkingSetTrim]::EmptyWorkingSet($process.Handle)
    $process.Refresh()
    $after = $process.WorkingSet64
    "{0} pid={1} workingSetBeforeMB={2:N1} workingSetAfterMB={3:N1}" -f `
      $process.ProcessName, $process.Id, ($before / 1MB), ($after / 1MB)
  } catch {
    "Failed to trim pid={0}: {1}" -f $process.Id, $_.Exception.Message
  }
}
