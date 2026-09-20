$ErrorActionPreference = 'Continue'
$p = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway --port 18789(?! --task)' } | Select-Object -First 1
if (-not $p) { $p = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway' } | Select-Object -First 1 }
Write-Output ("pid=" + $p.ProcessId + " creation=" + $p.CreationDate)
Write-Output ("cmd_has_gateway_cmd_parent check via ParentProcessId=" + $p.ParentProcessId)
$parent = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.ParentProcessId) -ErrorAction SilentlyContinue
if ($parent) { Write-Output ("parent_cmd=" + $parent.CommandLine) }

# Run live-bus syncProgress via node from plugin dir with env
$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Get-Content $envf | ForEach-Object { if ($_ -match '^([A-Z0-9_]+)=(.*)$') { Set-Item -Path ("Env:"+$Matches[1]) -Value $Matches[2] } }
$plugin = Join-Path $env:USERPROFILE '.openclaw\tablero-runbook'
# compile-less: call fetch equivalent to what syncProgress does
$headers = @{ Authorization = ('Bearer ' + $env:LIVE_WRITE_TOKEN) }
$before = (Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/api/runs') -UseBasicParsing -TimeoutSec 15).Content
$r = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/sync/progress/13') -Method POST -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 30
Write-Output ("hook_equiv_sync=" + [int]$r.StatusCode)
$after = (Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/api/runs') -UseBasicParsing -TimeoutSec 15).Content
Write-Output ("runs_has_fase13=" + ($after -match 'fase-13'))
Write-Output ("plugin_sha_marker live-bus.ts bytes=" + (Get-Item (Join-Path $plugin 'live-bus.ts')).Length)
Select-String -Path (Join-Path $plugin 'index.ts') -Pattern 'syncProgress' | ForEach-Object { Write-Output ("index:" + $_.Line.Trim()) }
