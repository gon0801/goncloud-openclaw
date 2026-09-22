# restart-openclaw-gateway.ps1
# Reinicia el gateway OpenClaw en Windows: mata el node.exe cuyo CommandLine
# corre openclaw\dist\index.js gateway y rearanca la tarea programada
# "OpenClaw Gateway". Verifica que el puerto 18789 vuelva a escuchar.
# Corre desde el checkout FUENTE (scripts/ no se despliega a runtime).
# Con un lease de cutover vigente se niega: el reinicio manual pelearia
# con la transaccion separada (Fase 16.6). Sin modulo verificable se sigue
# (sin fuente no hay cutover en curso).
$ErrorActionPreference = 'Stop'
$cutoverModule = Join-Path $PSScriptRoot 'runtime-separation\RuntimeSeparation.psm1'
if (Test-Path -LiteralPath $cutoverModule) {
  Import-Module $cutoverModule -Force -ErrorAction SilentlyContinue
  if (Get-Command Get-CutoverStandDownGeneration -ErrorAction SilentlyContinue) {
    $standGen = ''
    try { $standGen = Get-CutoverStandDownGeneration } catch { $standGen = '' }
    if ($standGen -ne '') {
      Write-Output "RESTART_FAIL: cutover $standGen en curso; el reinicio manual pelearia con la transaccion"
      exit 1
    }
  }
}
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
