$ErrorActionPreference = 'Continue'
try { $r=Invoke-WebRequest http://127.0.0.1:18789/ -UseBasicParsing -TimeoutSec 8; Write-Output ("gw="+[int]$r.StatusCode) } catch { Write-Output ("gw_ERR "+$_.Exception.Message) }

# Does gateway node process have LIVE_ env? Use handle via Get-Process not available; check cmdline parent cmd
$p = Get-CimInstance Win32_Process -Filter "ProcessId=2180" -ErrorAction SilentlyContinue
if (-not $p) {
  $p = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway --port 18789$' } | Select-Object -First 1
}
Write-Output ("listen_pid=" + $p.ProcessId)

$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Get-Content $envf | ForEach-Object { if ($_ -match '^([A-Z0-9_]+)=(.*)$') { Set-Item -Path ("Env:"+$Matches[1]) -Value $Matches[2] } }
try {
  $headers = @{ Authorization = ('Bearer ' + $env:LIVE_WRITE_TOKEN) }
  $r = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/')+'/sync/progress/13') -Method POST -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 30
  Write-Output ("sync13="+[int]$r.StatusCode)
} catch { Write-Output ("sync_ERR "+$_.Exception.Message) }

# Try tools/invoke with agentId implementer or main
# Read GATEWAY_AUTH from store is write-only; try without and with token from openclaw if in env of process - skip
# Use openclaw CLI if it can call tools
$out = & openclaw gateway call --help 2>&1 | Select-Object -First 20
Write-Output "=== openclaw help snippet ==="
$out

# Alternate: POST /tools/invoke with empty to see error (proves API up)
try {
  $body = '{"tool":"runbook.progress.get","args":{"fase":13},"agentId":"implementer"}'
  $r = Invoke-WebRequest http://127.0.0.1:18789/tools/invoke -Method POST -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 15
  Write-Output ("invoke="+[int]$r.StatusCode+" body="+$r.Content.Substring(0,[Math]::Min(200,$r.Content.Length)))
} catch {
  Write-Output ("invoke_ERR "+$_.Exception.Message)
  try {
    $resp = $_.Exception.Response
    if ($resp) {
      $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $b = $sr.ReadToEnd()
      Write-Output ("invoke_body=" + $b.Substring(0, [Math]::Min(300, $b.Length)))
    }
  } catch {}
}
