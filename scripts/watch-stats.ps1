param(
  [string]$Path = ".\.black-screen-repro\stats.ndjson"
)

Write-Host "Watching $Path"
Write-Host "Tip: if ackAgeMs or paintAgeMs keeps growing while sent increases, that side is stalled."

while (-not (Test-Path -LiteralPath $Path)) {
  Start-Sleep -Milliseconds 500
}

Get-Content -LiteralPath $Path -Wait | ForEach-Object {
  if (-not $_) { return }

  try {
    $s = $_ | ConvertFrom-Json
    $line = "{0} sent={1} edits={2} histAckAge={3} histPaintAge={4} chatAckAge={5} chatPaintAge={6} histVis={7} chatVis={8} histRows={9} chatRows={10} histSkipped={11} chatSkipped={12}" -f `
      $s.time, `
      $s.sent, `
      $s.workspaceEdits, `
      $s.history.ackAgeMs, `
      $s.history.paintAgeMs, `
      $s.chat.ackAgeMs, `
      $s.chat.paintAgeMs, `
      $s.history.visibility, `
      $s.chat.visibility, `
      $s.history.rows, `
      $s.chat.rows, `
      $s.history.skippedHiddenDom, `
      $s.chat.skippedHiddenDom
    Write-Host $line
  } catch {
    Write-Host $_
  }
}
