$ErrorActionPreference = 'Stop'
$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Get-Content $envf | ForEach-Object {
  if ($_ -match '^([A-Z0-9_]+)=(.*)$') {
    Set-Item -Path ("Env:" + $Matches[1]) -Value $Matches[2]
  }
}
Write-Output ("LIVE_BUS_URL=" + $env:LIVE_BUS_URL)
Write-Output ("TOKEN_LEN=" + $env:LIVE_WRITE_TOKEN.Length)
$h = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/healthz') -UseBasicParsing -TimeoutSec 15
Write-Output ("healthz=" + [int]$h.StatusCode + " body=" + $h.Content.Trim())
$headers = @{ Authorization = ('Bearer ' + $env:LIVE_WRITE_TOKEN) }
$r = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/sync/progress/13') -Method POST -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 30
Write-Output ("sync13=" + [int]$r.StatusCode + " bytes=" + $r.Content.Length)
$head = if ($r.Content.Length -gt 160) { $r.Content.Substring(0,160) } else { $r.Content }
Write-Output ("sync_head=" + $head)
