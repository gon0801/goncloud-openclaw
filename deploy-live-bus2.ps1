$ErrorActionPreference = 'Stop'
$plugin = Join-Path $env:USERPROFILE '.openclaw\tablero-runbook'
$tgz = Join-Path $env:LOCALAPPDATA 'Temp\tablero-runbook-4663702.tgz'
$stage = Join-Path $env:LOCALAPPDATA 'Temp\tablero-runbook-4663702'

# If plugin broken from prior attempt, restore latest bak
$baks = Get-ChildItem (Join-Path $env:USERPROFILE '.openclaw') -Directory -Filter 'tablero-runbook.bak-*' | Sort-Object Name -Descending
if ((-not (Test-Path (Join-Path $plugin 'index.ts'))) -and $baks) {
  Write-Output ("restoring " + $baks[0].FullName)
  if (Test-Path $plugin) { Remove-Item -Recurse -Force $plugin }
  Copy-Item -Recurse -Force $baks[0].FullName $plugin
}

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Path $stage | Out-Null
Push-Location $stage
tar -xzf $tgz
Pop-Location
# strip apple junk
Get-ChildItem $stage -Force -Recurse | Where-Object { $_.Name -like '._*' -or $_.Name -eq '.DS_Store' } | Remove-Item -Force -ErrorAction SilentlyContinue
if (-not (Test-Path (Join-Path $stage 'live-bus.ts'))) { throw 'live-bus.ts missing' }

# clear plugin then copy files only (not AppleDouble)
Get-ChildItem $plugin -Force | Remove-Item -Recurse -Force
Get-ChildItem $stage -Force | Where-Object { $_.Name -notlike '._*' } | ForEach-Object {
  Copy-Item -Recurse -Force $_.FullName (Join-Path $plugin $_.Name)
}
Write-Output ("files=" + ((Get-ChildItem $plugin -File).Name -join ','))
Write-Output ("has_live_bus=" + (Test-Path (Join-Path $plugin 'live-bus.ts')))
Write-Output ("has_sync=" + ((Select-String -Path (Join-Path $plugin 'index.ts') -Pattern 'syncProgress' -Quiet)))

# Restart gateway
Write-Output 'ending OpenClaw Gateway...'
schtasks /End /TN "OpenClaw Gateway" 2>$null | Out-Null
Start-Sleep -Seconds 3
# kill leftover node gateway if still up
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'openclaw' -and $_.CommandLine -match 'gateway' } | ForEach-Object {
  Write-Output ("kill pid=" + $_.ProcessId)
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2
schtasks /Run /TN "OpenClaw Gateway" | Out-Null
Start-Sleep -Seconds 10
$t = Get-ScheduledTask -TaskName 'OpenClaw Gateway'
Write-Output ("task_state=" + $t.State)
$procs = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'openclaw' -and $_.CommandLine -match 'gateway' })
Write-Output ("gateway_procs=" + $procs.Count)
