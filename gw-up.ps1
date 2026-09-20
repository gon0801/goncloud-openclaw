$ErrorActionPreference = 'Continue'
Write-Output 'alive'
$left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway' })
Write-Output ("gateway_procs=" + $left.Count)
schtasks /Query /TN "OpenClaw Gateway" /FO LIST | Select-String "Status|TaskName"
if ($left.Count -eq 0) {
  Write-Output 'starting...'
  schtasks /Run /TN "OpenClaw Gateway" | Out-Null
  Start-Sleep -Seconds 20
}
$left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway' })
Write-Output ("gateway_procs_after=" + $left.Count)
foreach ($p in $left) { Write-Output ("pid=" + $p.ProcessId) }
try {
  $r = Invoke-WebRequest http://127.0.0.1:18789/ -UseBasicParsing -TimeoutSec 10
  Write-Output ("gw=" + [int]$r.StatusCode)
} catch { Write-Output ("gw_ERR " + $_.Exception.Message) }

# plugin check
$plugin = Join-Path $env:USERPROFILE '.openclaw\tablero-runbook'
Write-Output ("live_bus=" + (Test-Path (Join-Path $plugin 'live-bus.ts')))
Write-Output ("syncProgress=" + ((Select-String -Path (Join-Path $plugin 'index.ts') -Pattern 'syncProgress' -Quiet)))

# BFF sync smoke
$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Get-Content $envf | ForEach-Object {
  if ($_ -match '^([A-Z0-9_]+)=(.*)$') { Set-Item -Path ("Env:"+$Matches[1]) -Value $Matches[2] }
}
Write-Output ("LIVE_BUS_URL=" + $env:LIVE_BUS_URL)
try {
  $h = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/healthz') -UseBasicParsing -TimeoutSec 10
  Write-Output ("bff=" + [int]$h.StatusCode)
} catch { Write-Output ("bff_ERR " + $_.Exception.Message) }
try {
  $headers = @{ Authorization = ('Bearer ' + $env:LIVE_WRITE_TOKEN) }
  $r = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/sync/progress/13') -Method POST -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 30
  Write-Output ("sync13=" + [int]$r.StatusCode)
} catch {
  Write-Output ("sync_ERR " + $_.Exception.Message)
}
