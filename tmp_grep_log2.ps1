$ErrorActionPreference = 'Continue'
$log = "$env:LOCALAPPDATA\Temp\openclaw\openclaw-2026-09-19.log"
$fs = [System.IO.File]::Open($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$sr = New-Object System.IO.StreamReader($fs)
$lines = New-Object System.Collections.Generic.List[string]
while ($null -ne ($line = $sr.ReadLine())) {
  $lines.Add($line)
  if ($lines.Count -gt 250) { [void]$lines.RemoveAt(0) }
}
$sr.Close(); $fs.Close()
Write-Output ("tail_lines=" + $lines.Count)
Write-Output '===TAIL==='
$lines | Select-Object -Last 100 | ForEach-Object { $_ }
Write-Output '===ERRLIKE==='
$lines | Where-Object { $_ -match 'error|Error|fail|auth|listen|EADDR|invalid|reject|config|warn' } | Select-Object -Last 50 | ForEach-Object { $_ }
