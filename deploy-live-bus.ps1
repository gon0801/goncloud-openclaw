$ErrorActionPreference = 'Stop'
$plugin = Join-Path $env:USERPROFILE '.openclaw\tablero-runbook'
$bak = Join-Path $env:USERPROFILE ('.openclaw\tablero-runbook.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$tgz = Join-Path $env:LOCALAPPDATA 'Temp\tablero-runbook-4663702.tgz'
$stage = Join-Path $env:LOCALAPPDATA 'Temp\tablero-runbook-4663702'

Write-Output ("plugin=" + $plugin)
if (-not (Test-Path $tgz)) { throw "missing tgz $tgz" }

# backup
if (Test-Path $plugin) {
  Copy-Item -Recurse -Force $plugin $bak
  Write-Output ("backup=" + $bak)
}

# extract with tar (Windows 10+)
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Path $stage | Out-Null
Push-Location $stage
tar -xzf $tgz
Pop-Location
if (-not (Test-Path (Join-Path $stage 'live-bus.ts'))) { throw 'live-bus.ts missing after extract' }

# replace plugin files (keep dir)
Get-ChildItem $plugin -Force | Remove-Item -Recurse -Force
Copy-Item -Recurse -Force (Join-Path $stage '*') $plugin
Write-Output ("has_live_bus=" + (Test-Path (Join-Path $plugin 'live-bus.ts')))
Write-Output ("has_sync_import=" + ((Select-String -Path (Join-Path $plugin 'index.ts') -Pattern 'syncProgress' -Quiet)))

# confirm env file
$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Write-Output ("live_bus_env=" + (Test-Path $envf) + " size=" + (Get-Item $envf).Length)
Get-Content $envf | ForEach-Object {
  if ($_ -match '^([A-Z0-9_]+)=(.*)$') { Write-Output ("key=" + $Matches[1] + " len=" + $Matches[2].Length) }
}

# Restart OpenClaw Gateway scheduled task
Write-Output 'restarting OpenClaw Gateway...'
schtasks /End /TN "OpenClaw Gateway" 2>$null | Out-Null
Start-Sleep -Seconds 2
schtasks /Run /TN "OpenClaw Gateway" | Out-Null
Start-Sleep -Seconds 8
$t = Get-ScheduledTask -TaskName 'OpenClaw Gateway' -ErrorAction SilentlyContinue
Write-Output ("task_state=" + $t.State)
# also check process
$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'openclaw' -and $_.CommandLine -match 'gateway' }
Write-Output ("gateway_procs=" + @($procs).Count)
foreach ($p in @($procs | Select-Object -First 3)) {
  Write-Output ("pid=" + $p.ProcessId + " cmdlen=" + $p.CommandLine.Length)
}
