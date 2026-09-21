$ErrorActionPreference = 'Continue'
Write-Output 'netstat 18789:'
netstat -ano | findstr 18789
Write-Output 'procs:'
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'node|cmd' -and $_.CommandLine -and $_.CommandLine -match 'openclaw|gateway' } | ForEach-Object {
  Write-Output ("pid=" + $_.ProcessId + " name=" + $_.Name + " cmd=" + $_.CommandLine.Substring(0, [Math]::Min(180, $_.CommandLine.Length)))
}
# Run gateway.cmd in foreground briefly to capture stderr - start process redirected
$log = Join-Path $env:TEMP 'gateway-boot-test.log'
if (Test-Path $log) { Remove-Item $log -Force }
$cmd = Join-Path $env:USERPROFILE '.openclaw\gateway.cmd'
Write-Output ("running " + $cmd + " -> " + $log)
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$cmd`" > `"$log`" 2>&1" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 12
Write-Output ("boot_pid=" + $p.Id + " hasexited=" + $p.HasExited)
netstat -ano | findstr 18789
if (Test-Path $log) {
  Write-Output '=== boot log ==='
  Get-Content $log -Tail 60
} else { Write-Output 'no boot log' }
# if listening, leave it; else kill test
try {
  $r = Invoke-WebRequest http://127.0.0.1:18789/ -UseBasicParsing -TimeoutSec 5
  Write-Output ("gw=" + [int]$r.StatusCode)
} catch { Write-Output ("gw_ERR " + $_.Exception.Message) }
