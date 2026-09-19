$ErrorActionPreference = 'Continue'
node "$env:USERPROFILE\.openclaw\tmp_restore_token.js"
Write-Output ("cli_mode=" + (& openclaw config get gateway.auth.mode 2>$null))
schtasks /End /TN 'OpenClaw Gateway' 2>&1 | Out-Null
Start-Sleep -Seconds 2
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'gateway --port 18789' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
schtasks /Run /TN 'OpenClaw Gateway' | Out-Null
for ($i=1; $i -le 24; $i++) {
  Start-Sleep -Seconds 5
  $listen = netstat -ano | findstr '0.0.0.0:18789'
  $status = ((schtasks /Query /TN 'OpenClaw Gateway' /FO LIST | findstr Status) -join ' ')
  Write-Output ("t=" + ($i*5) + " $status listen=" + [bool]$listen)
  if ($listen) { Write-Output $listen; break }
}
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:18789/runbook/tablero/12' -UseBasicParsing -TimeoutSec 15
  Write-Output ("local_http=" + [int]$r.StatusCode)
} catch {
  if ($_.Exception.Response) { Write-Output ("local_http=" + [int]$_.Exception.Response.StatusCode) }
  else { Write-Output ("local_err=" + $_.Exception.Message) }
}
Write-Output ("final_mode=" + ((Get-Content -Raw "$env:USERPROFILE\.openclaw\openclaw.json" | ConvertFrom-Json).gateway.auth.mode))
