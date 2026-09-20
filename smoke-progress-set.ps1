$ErrorActionPreference = 'Continue'
$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Get-Content $envf | ForEach-Object {
  if ($_ -match '^([A-Z0-9_]+)=(.*)$') { Set-Item -Path ("Env:"+$Matches[1]) -Value $Matches[2] }
}
Write-Output ("LIVE_BUS_URL=" + $env:LIVE_BUS_URL)
Write-Output ("TOKEN_LEN=" + $env:LIVE_WRITE_TOKEN.Length)
try {
  $g = Invoke-WebRequest -Uri 'http://127.0.0.1:18789/' -UseBasicParsing -TimeoutSec 10
  Write-Output ("gw_local=" + [int]$g.StatusCode)
} catch { Write-Output ("gw_local_ERR " + $_.Exception.Message) }
$procs = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway' })
Write-Output ("gateway_procs=" + $procs.Count)
foreach ($p in $procs) { Write-Output ("pid=" + $p.ProcessId) }
try {
  $headers = @{ Authorization = ('Bearer ' + $env:LIVE_WRITE_TOKEN) }
  $r = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/sync/progress/13') -Method POST -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 30
  Write-Output ("sync13=" + [int]$r.StatusCode + " bytes=" + $r.Content.Length)
} catch { Write-Output ("sync_ERR " + $_.Exception.Message) }
try {
  $h = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/healthz') -UseBasicParsing -TimeoutSec 10
  Write-Output ("bff_healthz=" + [int]$h.StatusCode)
} catch { Write-Output ("bff_ERR " + $_.Exception.Message) }
try {
  $runs = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/api/runs') -UseBasicParsing -TimeoutSec 15
  Write-Output ("runs_head=" + $runs.Content.Substring(0, [Math]::Min(280, $runs.Content.Length)))
} catch { Write-Output ("runs_ERR " + $_.Exception.Message) }
