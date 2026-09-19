$ErrorActionPreference = 'Continue'
Write-Output ("mode_pre=" + (& openclaw config get gateway.auth.mode 2>$null))
Write-Output '===RESTART==='
# Use official restart; it should not hang forever if already configured
$job = Start-Job -ScriptBlock { & openclaw gateway restart 2>&1 | Out-String }
Wait-Job $job -Timeout 90 | Out-Null
if ($job.State -ne 'Completed') {
  Write-Output 'cli_restart_timeout; force schtasks'
  Stop-Job $job -ErrorAction SilentlyContinue
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  schtasks /End /TN 'OpenClaw Gateway' 2>&1 | Out-String | Write-Output
  Start-Sleep -Seconds 3
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'gateway --port 18789' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 2
  schtasks /Run /TN 'OpenClaw Gateway' 2>&1 | Out-String | Write-Output
} else {
  Write-Output ($job | Receive-Job)
  Remove-Job $job -Force -ErrorAction SilentlyContinue
}
# wait for listen (warmup can take ~40s)
for ($i=0; $i -lt 24; $i++) {
  Start-Sleep -Seconds 5
  $listening = netstat -ano | findstr '0.0.0.0:18789'
  if ($listening) {
    Write-Output ("listening_after_s=" + ($i*5+5))
    Write-Output $listening
    break
  }
  Write-Output ("wait_s=" + ($i*5+5))
}
Write-Output ("mode_post=" + (& openclaw config get gateway.auth.mode 2>$null))
$j = Get-Content -Raw "$env:USERPROFILE\.openclaw\openclaw.json" | ConvertFrom-Json
Write-Output ("file_mode=" + $j.gateway.auth.mode)
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:18789/runbook/tablero/12' -UseBasicParsing -TimeoutSec 15
  Write-Output ("local_http=" + [int]$r.StatusCode)
} catch {
  if ($_.Exception.Response) { Write-Output ("local_http=" + [int]$_.Exception.Response.StatusCode) }
  else { Write-Output ("local_err=" + $_.Exception.Message) }
}
