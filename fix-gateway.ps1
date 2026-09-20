$ErrorActionPreference = 'Continue'
Write-Output '=== kill all gateway node procs ==='
Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -and (
    $_.CommandLine -match 'index.js gateway' -or
    ($_.CommandLine -match 'openclaw' -and $_.CommandLine -match 'gateway')
  )
} | ForEach-Object {
  Write-Output ("kill " + $_.ProcessId)
  Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
schtasks /End /TN "OpenClaw Gateway" 2>$null | Out-Null
Start-Sleep -Seconds 4
$left = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway' })
Write-Output ("left=" + $left.Count)

# show last log lines
$logDir = Join-Path $env:USERPROFILE '.openclaw\logs'
if (Test-Path $logDir) {
  Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
    Write-Output ("log=" + $_.Name + " mtime=" + $_.LastWriteTime + " size=" + $_.Length)
  }
  $latest = Get-ChildItem $logDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) {
    Write-Output ("tail=" + $latest.FullName)
    Get-Content $latest.FullName -Tail 40
  }
}

# confirm env loader in gateway.cmd
Write-Output '=== gateway.cmd head ==='
Get-Content (Join-Path $env:USERPROFILE '.openclaw\gateway.cmd') | Select-Object -First 12

Write-Output '=== start gateway ==='
schtasks /Run /TN "OpenClaw Gateway" | Out-Null
Start-Sleep -Seconds 15
$t = Get-ScheduledTask -TaskName 'OpenClaw Gateway'
Write-Output ("task_state=" + $t.State)
$procs = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match 'index.js gateway' })
Write-Output ("gateway_procs=" + $procs.Count)
foreach ($p in $procs) { Write-Output ("pid=" + $p.ProcessId) }

for ($i=0; $i -lt 8; $i++) {
  try {
    $r = Invoke-WebRequest http://127.0.0.1:18789/ -UseBasicParsing -TimeoutSec 5
    Write-Output ("gw_local=" + [int]$r.StatusCode + " attempt=" + $i)
    break
  } catch {
    Write-Output ("gw_wait attempt=" + $i + " err=" + $_.Exception.Message)
    Start-Sleep -Seconds 3
  }
}

# sync smoke
$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Get-Content $envf | ForEach-Object {
  if ($_ -match '^([A-Z0-9_]+)=(.*)$') { Set-Item -Path ("Env:"+$Matches[1]) -Value $Matches[2] }
}
try {
  $headers = @{ Authorization = ('Bearer ' + $env:LIVE_WRITE_TOKEN) }
  $r = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/') + '/sync/progress/13') -Method POST -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 30
  Write-Output ("sync13=" + [int]$r.StatusCode)
} catch {
  Write-Output ("sync_ERR " + $_.Exception.Message)
  if ($_.Exception.Response) {
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    Write-Output ("sync_body=" + $reader.ReadToEnd().Substring(0, [Math]::Min(300, 9999)))
  }
}
