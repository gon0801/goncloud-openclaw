$ErrorActionPreference = 'Continue'
Write-Output ("mode=" + (& openclaw config get gateway.auth.mode 2>$null))
# search for auth mode none guard in installed package (quick)
$pkg = 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist'
Select-String -Path (Join-Path $pkg '*.mjs') -Pattern 'auth\.mode|mode === "none"|mode==="none"|authentication is configured|refuse.*auth|auth.*required' -SimpleMatch:$false -ErrorAction SilentlyContinue |
  Select-Object -First 30 | ForEach-Object { $_.Filename + ':' + $_.LineNumber + ':' + $_.Line.Substring(0,[Math]::Min(220,$_.Line.Length)) }

Write-Output '===KILL_AND_START==='
schtasks /End /TN 'OpenClaw Gateway' 2>&1 | Out-Null
Start-Sleep -Seconds 2
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'gateway --port 18789' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
schtasks /Run /TN 'OpenClaw Gateway' | Out-Null
# poll processes and ports for 90s
for ($i=1; $i -le 18; $i++) {
  Start-Sleep -Seconds 5
  $procs = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'gateway --port 18789' })
  $listen = netstat -ano | findstr '0.0.0.0:18789'
  $status = (schtasks /Query /TN 'OpenClaw Gateway' /FO LIST | findstr Status)
  Write-Output ("t=" + ($i*5) + " procs=" + $procs.Count + " " + $status + " listen=" + [bool]$listen)
  if ($listen) { Write-Output $listen; break }
}
# dump newest log lines with FileShare
$log = "$env:LOCALAPPDATA\Temp\openclaw\openclaw-2026-09-19.log"
$fs = [System.IO.File]::Open($log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$sr = New-Object System.IO.StreamReader($fs)
$buf = New-Object System.Collections.Generic.List[string]
while ($null -ne ($line = $sr.ReadLine())) { $buf.Add($line); if ($buf.Count -gt 80) { [void]$buf.RemoveAt(0) } }
$sr.Close(); $fs.Close()
$out = "$env:USERPROFILE\.openclaw\tmp_gateway_tail2.txt"
$buf | Set-Content $out -Encoding utf8
Write-Output '===TAIL_FILTER==='
$buf | Where-Object { $_ -match 'auth|listen|error|Error|fail|none|bind|refus|invalid|Security|WARN|listening' } | ForEach-Object {
  # keep short
  if ($_ -match '"message":"([^"]+)"') { $matches[1] }
  elseif ($_ -match '"1":"([^"]+)"') { $matches[1] }
  else { $_.Substring(0, [Math]::Min(300, $_.Length)) }
}
