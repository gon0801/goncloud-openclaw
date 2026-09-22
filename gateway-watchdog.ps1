$ErrorActionPreference = "SilentlyContinue"

# OpenClaw Gateway watchdog (runs every 1 min via "OpenClaw Gateway Watchdog" task).
# Recovers TWO failure modes:
#   1. Nothing listening on the gateway port  -> (re)start the "OpenClaw Gateway" task.
#   2. Port listening but gateway not responding (wedged event loop: accepts TCP,
#      serves nothing, e.g. 2026-09-21 outage) -> kill the wedged node tree, restart task.
# Boot grace: a fresh gateway takes minutes before it serves; never kill young procs.
# Cutover stand-down: with a valid lease for a nonterminal generation, do nothing.

$gatewayPort = 18789
$gatewayTask = "OpenClaw Gateway"
$logFile = $env:OPENCLAW_WATCHDOG_LOG
if ([string]::IsNullOrEmpty($logFile)) {
    $logFile = "C:\Users\ehven\.openclaw\logs\gateway-watchdog.log"
}
$bootGraceSeconds = 300
$httpTimeoutSec = 90

function Watchdog-Log($msg) {
    Add-Content -Path $logFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg)
}

# Stand-down de cutover (Fase 16.6): con un lease valido para una generacion
# no terminal, el watchdog se aparta y deja actuar a la transaccion separada.
# El modulo vive en el checkout FUENTE (scripts/ no se despliega a runtime);
# si falta o no sabe de stand-down, se sigue como siempre (fallo cerrado
# hacia proteger el servicio: sin lease verificable no hay pausa).
$cutoverModule = $env:OPENCLAW_CUTOVER_MODULE
if ([string]::IsNullOrEmpty($cutoverModule)) {
    $cutoverModule = 'C:\Users\ehven\src\goncloud-openclaw\scripts\runtime-separation\RuntimeSeparation.psm1'
}
if (Test-Path -LiteralPath $cutoverModule) {
    Import-Module $cutoverModule -Force -ErrorAction SilentlyContinue
    if (Get-Command Get-CutoverStandDownGeneration -ErrorAction SilentlyContinue) {
        $standGen = ''
        try { $standGen = Get-CutoverStandDownGeneration } catch { $standGen = '' }
        if ($standGen -ne '') {
            Watchdog-Log "cutover $standGen vigente; stand-down"
            exit 0
        }
    }
}

function Get-GatewaySupervisorProcs {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -like "*openclaw*index.js*gateway --port $gatewayPort*" }
}

$listener = Get-NetTCPConnection -State Listen -LocalPort $gatewayPort -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $listener) {
    $taskState = (Get-ScheduledTask -TaskName $gatewayTask -ErrorAction SilentlyContinue).State
    if ($taskState -eq "Running") {
        exit 0  # boot in progress; task already starting
    }
    Watchdog-Log "no listener on $gatewayPort (task state: $taskState); starting $gatewayTask"
    Start-ScheduledTask -TaskName $gatewayTask
    exit 0
}

# Port is listening. Is the gateway actually serving?
$responsive = $false
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$gatewayPort/" -TimeoutSec $httpTimeoutSec -UseBasicParsing
    if ($r.StatusCode -lt 500) { $responsive = $true }
} catch {
    $responsive = $false
}

if ($responsive) {
    exit 0
}

# Wedged: listening but not responding. Respect boot grace via listener proc age.
$listenerPid = $listener.OwningProcess
$listenerProc = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
if ($listenerProc) {
    $listenerAge = ((Get-Date) - $listenerProc.StartTime).TotalSeconds
    if ($listenerAge -lt $bootGraceSeconds) {
        exit 0  # young listener still booting; wait
    }
}

Watchdog-Log "WEDGED: listening pid=$listenerPid not responding in ${httpTimeoutSec}s; killing tree"

$pidsToKill = @($listenerPid)
foreach ($sup in @(Get-GatewaySupervisorProcs)) {
    if ($sup.ProcessId -ne $listenerPid) {
        $pidsToKill += $sup.ProcessId
    }
}

foreach ($targetPid in ($pidsToKill | Sort-Object -Unique)) {
    Start-Process -FilePath "taskkill.exe" -ArgumentList "/F", "/T", "/PID", $targetPid -NoNewWindow -Wait
}

Start-Sleep -Seconds 5
$stillThere = Get-NetTCPConnection -State Listen -LocalPort $gatewayPort -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($stillThere) {
    Watchdog-Log "port $gatewayPort still held by pid=$($stillThere.OwningProcess) after taskkill; leaving for next run"
    exit 0
}

Start-ScheduledTask -TaskName $gatewayTask
Watchdog-Log "restart issued for $gatewayTask"
exit 0
