# restart-openclaw-gateway.ps1
# Reinicia el gateway OpenClaw en Windows: mata el node.exe cuyo CommandLine
# corre openclaw\dist\index.js gateway y rearanca la tarea programada
# "OpenClaw Gateway". Verifica que el puerto 18789 vuelva a escuchar.
$ErrorActionPreference = 'Stop'
$procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match 'openclaw\\dist\\index\.js gateway' }
if (-not $procs) { Write-Output 'RESTART_FAIL: no se encontro proceso gateway'; exit 1 }
foreach ($p in $procs) {
  Stop-Process -Id $p.ProcessId -Force
  Write-Output "killed pid $($p.ProcessId)"
}
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName 'OpenClaw Gateway'
$ok = $false
foreach ($i in 1..20) {
  Start-Sleep -Seconds 2
  if (Get-NetTCPConnection -State Listen -LocalPort 18789 -ErrorAction SilentlyContinue) { $ok = $true; break }
}
if ($ok) { Write-Output 'RESTART_OK: gateway escuchando en 18789' }
else { Write-Output 'RESTART_FAIL: 18789 no volvio a escuchar en 40s'; exit 1 }
