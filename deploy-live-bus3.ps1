$ErrorActionPreference = 'Stop'
$plugin = Join-Path $env:USERPROFILE '.openclaw\tablero-runbook'
$zip = Join-Path $env:LOCALAPPDATA 'Temp\tablero-runbook-4663702.zip'
$stage = Join-Path $env:LOCALAPPDATA 'Temp\trb-stage-clean'

# cleanup cursed stage dirs
foreach ($d in @(
  (Join-Path $env:LOCALAPPDATA 'Temp\tablero-runbook-4663702'),
  $stage
)) {
  if (Test-Path $d) {
    cmd /c "rd /s /q `"$d`"" 2>$null | Out-Null
  }
}

# ensure plugin exists (restore bak if needed)
if (-not (Test-Path (Join-Path $plugin 'index.ts'))) {
  $bak = Get-ChildItem (Join-Path $env:USERPROFILE '.openclaw') -Directory -Filter 'tablero-runbook.bak-*' | Sort-Object Name -Descending | Select-Object -First 1
  if ($bak) {
    if (Test-Path $plugin) { cmd /c "rd /s /q `"$plugin`"" | Out-Null }
    Copy-Item -Recurse -Force $bak.FullName $plugin
    Write-Output ("restored " + $bak.Name)
  }
}

New-Item -ItemType Directory -Path $stage | Out-Null
Expand-Archive -Path $zip -DestinationPath $stage -Force
if (-not (Test-Path (Join-Path $stage 'live-bus.ts'))) { throw 'no live-bus.ts' }

# wipe plugin contents via cmd rd then recreate
$bak2 = Join-Path $env:USERPROFILE ('.openclaw\tablero-runbook.bak-pre4663702')
if (Test-Path $plugin) {
  if (Test-Path $bak2) { cmd /c "rd /s /q `"$bak2`"" | Out-Null }
  Rename-Item $plugin (Split-Path $bak2 -Leaf)
  Write-Output ("renamed_old_to=" + $bak2)
}
New-Item -ItemType Directory -Path $plugin | Out-Null
Copy-Item -Recurse -Force (Join-Path $stage '*') $plugin
Write-Output ("has_live_bus=" + (Test-Path (Join-Path $plugin 'live-bus.ts')))
Write-Output ("has_sync=" + ((Select-String -Path (Join-Path $plugin 'index.ts') -Pattern 'syncProgress' -Quiet)))
Get-ChildItem $plugin -File | ForEach-Object { Write-Output ("file=" + $_.Name) }

Write-Output 'restart gateway'
schtasks /End /TN "OpenClaw Gateway" 2>$null | Out-Null
Start-Sleep -Seconds 3
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'openclaw.+gateway|gateway.+openclaw|dist\\index.js gateway' } | ForEach-Object {
  Write-Output ("kill " + $_.ProcessId)
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2
schtasks /Run /TN "OpenClaw Gateway" | Out-Null
Start-Sleep -Seconds 12
$t = Get-ScheduledTask -TaskName 'OpenClaw Gateway'
Write-Output ("task_state=" + $t.State)
$n = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway' }).Count
Write-Output ("gateway_procs=" + $n)
