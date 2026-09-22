# Invoke-OpenClawCutover.ps1 — transaccion separada del cutover (Fase 16.6).
#
# El controlador despacha una vez y despues solo lee el recibo; nunca espera
# otro turno mediado por el gateway mientras esta caido:
#
#   -Dispatch  Valida args, crea lease + estado (ACL restringida), crea el
#              one-shot y el dead-man por ruta absoluta a ESTE script, y
#              arranca el one-shot. Sale 0 e imprime generation/receipt/state.
#   -Run       stop -> payload -> restart -> finalize con reanudacion
#              idempotente, tiempos duros y try/finally. El exito escribe DONE
#              terminal y cancela el dead-man.
#   -DeadMan   Bloquea y relee el estado justo antes de recuperar. Con DONE
#              sale sin mutar; si no, recupera servicio y escribe ROLLED_BACK
#              solo para la misma generacion no terminal. Nunca sobrescribe
#              un terminal.
#
# Todo acceso a tareas es schtasks CLI (fingeable en humo); jamas los cmdlets
# ScheduledTask. Sintaxis compatible con Windows PowerShell 5.1.
#
# Contrato del payload: script .ps1 sin argumentos (los args se hornean en un
# wrapper) que termina con `exit` explicito. El job propaga el codigo como
# dato (PAYLOAD-EXIT:) porque el engine traga `exit N` interno sin fallar el
# job (medido en 7; el `throw` si falla). Sin codigo, vacio vale 0.
param(
  [switch]$Dispatch,
  [switch]$Run,
  [switch]$DeadMan,
  [string]$Generation = '',
  [string]$PayloadScript = '',
  [string]$PayloadSha256 = '',
  [string]$StateRoot = '',
  [string]$GatewayTask = 'OpenClaw Gateway',
  [string]$WatchdogTask = 'OpenClaw Gateway Watchdog',
  [string]$HealthUrl = '',
  [int]$LeaseMinutes = 120,
  [int]$DeadManAfterMinutes = 90,
  [int]$PhaseTimeoutSec = 600,
  [int]$GlobalTimeoutSec = 3600,
  [int]$ProbeTimeoutSec = 10,
  [int]$LockTimeoutSec = 30,
  [int]$RecoverTimeoutSec = 600,
  [int]$DeadManWaitSec = 3600,
  [int]$HeartbeatStaleSec = 120,
  [string]$OpenClawVersion = '',
  [string]$SourceSha = '',
  [string]$HostName = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeSeparation.psm1') -Force

$modeCount = 0
if ($Dispatch) { $modeCount++ }
if ($Run) { $modeCount++ }
if ($DeadMan) { $modeCount++ }
if ($modeCount -ne 1) {
  Write-Output 'se exige exactamente un modo: -Dispatch, -Run o -DeadMan'
  exit 1
}

function Format-CutoverUtc {
  param([Parameter(Mandatory = $true)][DateTime]$Instant)
  return ($Instant.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
}

function New-CutoverGeneration {
  return (([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')) + '-' +
    [Guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Test-CutoverAbsolutePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ($Path -cmatch '^[A-Za-z]:[\\/]') { return $true }
  if ($Path.StartsWith('\\')) { return $true }
  if ($Path.StartsWith('/')) { return $true }
  return $false
}

function Invoke-CutoverSchtasks {
  param(
    [Parameter(Mandatory = $true)][string[]]$SchtasksArgs,
    [Parameter(Mandatory = $true)][string]$Step
  )
  $out = (& schtasks @SchtasksArgs 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) {
    throw ("{0}: schtasks salio {1}: {2}" -f $Step, $LASTEXITCODE, (Remove-SecretValue -Text $out))
  }
  return $out
}

function Test-CutoverTaskExists {
  param([Parameter(Mandatory = $true)][string]$Name)
  & schtasks /query /tn $Name 2>&1 | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Invoke-CutoverStep {
  param(
    [Parameter(Mandatory = $true)][string]$Step,
    [Parameter(Mandatory = $true)][string[]]$SchtasksArgs,
    [Parameter(Mandatory = $true)]$Commands
  )
  $out = (& schtasks @SchtasksArgs 2>&1 | Out-String)
  [void]$Commands.Add([PSCustomObject]@{ name = $Step; exit = $LASTEXITCODE })
  if ($LASTEXITCODE -ne 0) {
    throw ("{0}: schtasks salio {1}: {2}" -f $Step, $LASTEXITCODE, (Remove-SecretValue -Text $out))
  }
  return $out
}

function Write-CutoverTextAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { throw "directorio destino inexistente: $dir" }
  $tmp = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
  try {
    [IO.File]::WriteAllText($tmp, $Content, (New-Object Text.UTF8Encoding $false))
    $fs = [IO.File]::Open($tmp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
      $fs.Flush($true)
    } finally {
      $fs.Close()
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    throw
  }
}

function Resolve-CutoverRoot {
  param([string]$Wanted = '')
  if ([string]::IsNullOrEmpty($Wanted)) { return (Get-CutoverStateRoot) }
  return $Wanted
}

function Resolve-CutoverHost {
  param([string]$Wanted = '')
  if ([string]::IsNullOrEmpty($Wanted)) { return ([System.Environment]::MachineName) }
  return $Wanted
}

function Get-CutoverHealth {
  param(
    [Parameter(Mandatory = $true)][string]$HealthUrl,
    [Parameter(Mandatory = $true)][int]$ProbeTimeoutSec
  )
  $h = [ordered]@{ startupz = 0; readyz = 0 }
  foreach ($ep in @('/startupz', '/readyz')) {
    $k = $ep.TrimStart('/')
    try {
      $r = Invoke-WebRequest -Uri ($HealthUrl + $ep) -TimeoutSec $ProbeTimeoutSec -UseBasicParsing
      $h[$k] = [int]$r.StatusCode
    } catch {
      $code = 0
      $ex = $_.Exception
      if ($null -ne $ex.StatusCode) {
        try { $code = [int]$ex.StatusCode } catch { $code = 0 }
      } elseif ($null -ne $ex.Response -and $null -ne $ex.Response.StatusCode) {
        try { $code = [int]$ex.Response.StatusCode } catch { $code = 0 }
      }
      $h[$k] = $code
    }
  }
  return $h
}

function Get-CutoverTaskStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    $Commands = $null
  )
  try {
    $out = Invoke-CutoverSchtasks -Step ("leer {0}" -f $Name) -SchtasksArgs @('/query', '/tn', $Name, '/fo', 'LIST', '/v')
    if ($null -ne $Commands) { [void]$Commands.Add([PSCustomObject]@{ name = ("leer {0}" -f $Name); exit = 0 }) }
  } catch {
    if ($null -ne $Commands) { [void]$Commands.Add([PSCustomObject]@{ name = ("leer {0}" -f $Name); exit = 1 }) }
    throw
  }
  $m = [regex]::Match($out, '(?m)^Status:\s*(.+?)\s*$')
  if (-not $m.Success) { throw ("sin Status en /query de {0}" -f $Name) }
  return $m.Groups[1].Value
}

function Get-CutoverReceiptSchemaPath {
  $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
  return (Join-Path (Join-Path $repo 'docs/spec') 'runtime-separation-receipt.v1.schema.json')
}

function Lock-CutoverState {
  param(
    [Parameter(Mandatory = $true)][string]$LockPath,
    [Parameter(Mandatory = $true)][int]$TimeoutSec
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
  while ($true) {
    try {
      return [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
      if ([DateTime]::UtcNow -ge $deadline) { throw ("lock ocupado tras {0}s" -f $TimeoutSec) }
      Start-Sleep -Milliseconds 200
    }
  }
}

function Read-CutoverPair {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  $leasePath = Join-Path $StateRoot 'lease.json'
  if (-not (Test-Path -LiteralPath $leasePath)) { throw 'lease ausente' }
  $leaseRaw = Get-Content -Raw -LiteralPath $leasePath
  if (-not (Test-CutoverLeaseObject -LeaseJson $leaseRaw)) { throw 'lease malformado' }
  $lease = $leaseRaw | ConvertFrom-Json
  if (-not (Test-Path -LiteralPath $lease.statePath)) { throw 'estado ausente' }
  $stateRaw = Get-Content -Raw -LiteralPath $lease.statePath
  if (-not (Test-CutoverStateObject -StateJson $stateRaw)) { throw 'estado malformado' }
  $state = $stateRaw | ConvertFrom-Json
  if ($state.generation -cne $lease.generation) { throw 'lease y estado de distinta generacion' }
  return @{ lease = $lease; state = $state }
}

function Write-CutoverLog {
  param(
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter(Mandatory = $true)][string]$Text
  )
  $dir = Split-Path -Parent $LogPath
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $line = '[{0}] {1}' -f (Format-CutoverUtc -Instant ([DateTime]::UtcNow)), (Remove-SecretValue -Text $Text)
  Add-Content -LiteralPath $LogPath -Value $line
  Write-Output $line
}

function Add-CutoverObservation {
  param(
    [Parameter(Mandatory = $true)]$List,
    [Parameter(Mandatory = $true)][string]$Text
  )
  if ($List.Count -ge 20) { return }
  [void]$List.Add((Remove-SecretValue -Text $Text))
}

function Write-CutoverReceipt {
  param(
    [Parameter(Mandatory = $true)][string]$Rt,
    [Parameter(Mandatory = $true)][string]$Gen,
    [Parameter(Mandatory = $true)][string]$Result,
    [Parameter(Mandatory = $true)]$Health,
    [Parameter(Mandatory = $true)]$Commands,
    [Parameter(Mandatory = $true)]$Inputs,
    [Parameter(Mandatory = $true)][string[]]$Observations,
    [Parameter(Mandatory = $true)][string]$Artifact,
    [Parameter(Mandatory = $true)][string]$DeadlineUtc,
    [Parameter(Mandatory = $true)][string]$StartedAt,
    [Parameter(Mandatory = $true)][string]$SrcSha,
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$SchemaPath
  )
  $doc = [ordered]@{
    schema = 'runtime-separation-receipt.v1'; phase = '16.6'
    startedAt = $StartedAt; endedAt = (Format-CutoverUtc -Instant ([DateTime]::UtcNow))
    sourceSha = $SrcSha; host = $HostName; openclawVersion = $Version
    commands = @($Commands); inputs = $Inputs; observations = @($Observations)
    health = [ordered]@{ startupz = $Health['startupz']; readyz = $Health['readyz'] }
    result = $Result
    rollback = [ordered]@{ artifact = $Artifact; deadlineUtc = $DeadlineUtc }
  }
  $json = (New-Object PSObject -Property $doc) | ConvertTo-Json -Depth 5 -Compress
  $name = "cutover-{0}.json" -f $Gen
  Write-ReceiptAtomic -ReceiptJson $json -Path (Join-Path (Join-Path $Rt 'receipts') $name) -SchemaPath $SchemaPath
}

function Assert-CutoverAlive {
  param(
    [Parameter(Mandatory = $true)][string]$Rt,
    [Parameter(Mandatory = $true)][string]$Gen,
    [Parameter(Mandatory = $true)][int]$MyAttempt,
    [Parameter(Mandatory = $true)][DateTime]$GlobalDeadline,
    [Parameter(Mandatory = $true)][string]$LockPath,
    [Parameter(Mandatory = $true)][int]$LockTimeoutSec
  )
  if ([DateTime]::UtcNow -ge $GlobalDeadline) { throw 'plazo global excedido' }
  $fs = $null
  try {
    $fs = Lock-CutoverState -LockPath $LockPath -TimeoutSec $LockTimeoutSec
    $pair = Read-CutoverPair -StateRoot $Rt
    if ($pair.state.generation -cne $Gen) { throw 'generacion ajena al estado' }
    if ($pair.state.status -cne 'IN_PROGRESS') { throw ("terminal ajeno: {0}" -f $pair.state.status) }
    if ($pair.state.attempts -ne $MyAttempt) { throw 'run desplazado por otro intento' }
    $pair.state.updatedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
    $sj = ($pair.state | ConvertTo-Json -Depth 5 -Compress)
    if (-not (Test-CutoverStateObject -StateJson $sj)) { throw 'latido regenerado invalido' }
    Write-CutoverTextAtomic -Content $sj -Path $pair.lease.statePath
  } finally {
    if ($null -ne $fs) { $fs.Close() }
  }
}

function Complete-CutoverPhase {
  param(
    [Parameter(Mandatory = $true)][string]$Rt,
    [Parameter(Mandatory = $true)][string]$Gen,
    [Parameter(Mandatory = $true)][int]$MyAttempt,
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][string]$LockPath,
    [Parameter(Mandatory = $true)][int]$LockTimeoutSec
  )
  $fs = $null
  try {
    $fs = Lock-CutoverState -LockPath $LockPath -TimeoutSec $LockTimeoutSec
    $pair = Read-CutoverPair -StateRoot $Rt
    if ($pair.state.generation -cne $Gen) { throw 'generacion ajena al estado' }
    if ($pair.state.status -cne 'IN_PROGRESS') { throw ("terminal ajeno: {0}" -f $pair.state.status) }
    if ($pair.state.attempts -ne $MyAttempt) { throw 'run desplazado por otro intento' }
    $done = @($pair.state.completedPhases)
    if ($done -notcontains $Phase) { $done += $Phase }
    $pair.state.completedPhases = $done
    $pair.state.updatedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
    $sj = ($pair.state | ConvertTo-Json -Depth 5 -Compress)
    if (-not (Test-CutoverStateObject -StateJson $sj)) { throw 'fase regenerada invalida' }
    Write-CutoverTextAtomic -Content $sj -Path $pair.lease.statePath
  } finally {
    if ($null -ne $fs) { $fs.Close() }
  }
}

if ($Dispatch) {
  if ([string]::IsNullOrEmpty($HealthUrl) -or $HealthUrl -cnotmatch '^http://(127\.0\.0\.1|localhost)(:\d+)?$') {
    Write-Output 'dispatch: HealthUrl debe ser origen loopback sin ruta'; exit 1
  }
  if ($OpenClawVersion -cnotmatch '^\d{4}\.\d+\.\d+$') {
    Write-Output 'dispatch: OpenClawVersion con forma rara'; exit 1
  }
  if ($SourceSha -cnotmatch '^[0-9a-f]{40}$') {
    Write-Output 'dispatch: SourceSha debe ser 40 hex'; exit 1
  }
  if (-not (Test-CutoverAbsolutePath -Path $PayloadScript)) {
    Write-Output 'dispatch: PayloadScript debe ser ruta absoluta'; exit 1
  }
  if ($PayloadScript -notmatch '(?i)\.ps1$') {
    Write-Output 'dispatch: PayloadScript debe ser .ps1'; exit 1
  }
  if (-not (Test-Path -LiteralPath $PayloadScript)) {
    Write-Output 'dispatch: PayloadScript inexistente'; exit 1
  }
  if ($LeaseMinutes -le 0 -or $DeadManAfterMinutes -le 0) {
    Write-Output 'dispatch: plazos positivos'; exit 1
  }
  if ($DeadManAfterMinutes -ge $LeaseMinutes) {
    Write-Output 'dispatch: el dead-man debe disparar antes de que expire el lease'; exit 1
  }
  if ($GlobalTimeoutSec -le 0 -or $PhaseTimeoutSec -le 0 -or $ProbeTimeoutSec -le 0) {
    Write-Output 'dispatch: timeouts positivos'; exit 1
  }
  if ($RecoverTimeoutSec -le 0 -or $DeadManWaitSec -le 0 -or $HeartbeatStaleSec -le 0 -or $LockTimeoutSec -le 0) {
    Write-Output 'dispatch: plazos positivos'; exit 1
  }
  $root = Resolve-CutoverRoot -Wanted $StateRoot
  $hostName = Resolve-CutoverHost -Wanted $HostName
  $gen = New-CutoverGeneration
  $TaskName = 'OpenClaw Cutover'
  $DeadManTaskName = 'OpenClaw Cutover DeadMan'
  $self = $PSCommandPath
  if (-not (Test-CutoverAbsolutePath -Path $self)) {
    Write-Output 'dispatch: ruta propia no absoluta'; exit 1
  }
  $nowLocal = Get-Date
  $nowUtc = [DateTime]::UtcNow
  $expUtc = $nowUtc.AddMinutes($LeaseMinutes)
  $dmUtc = $nowUtc.AddMinutes($DeadManAfterMinutes)
  $dmLocal = $nowLocal.AddMinutes($DeadManAfterMinutes)
  $backstopLocal = $nowLocal.AddMinutes(2)
  $payloadSha = (Get-FileHash -LiteralPath $PayloadScript -Algorithm SHA256).Hash.ToLowerInvariant()
  $leasePath = Join-Path $root 'lease.json'
  $statePath = Join-Path $root 'state.json'
  $receiptPath = Join-Path (Join-Path $root 'receipts') ("cutover-{0}.json" -f $gen)

  foreach ($d in @($root, (Join-Path $root 'receipts'), (Join-Path $root 'logs'))) {
    if (-not (Test-Path -LiteralPath $d)) {
      [void](New-Item -ItemType Directory -Path $d -Force)
    }
  }
  & icacls $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' /grant:r '*S-1-5-32-544:(OI)(CI)F' 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Output 'dispatch: icacls lockdown fallo'; exit 1 }
  if (-not (Test-CutoverAcl -StateRoot $root)) {
    Write-Output 'dispatch: ACL sin restringir tras lockdown'; exit 1
  }
  if (Test-CutoverTaskExists -Name $TaskName) {
    Write-Output ("dispatch: la tarea existe sin cancelar: {0}" -f $TaskName); exit 1
  }
  if (Test-CutoverTaskExists -Name $DeadManTaskName) {
    Write-Output ("dispatch: la tarea existe sin cancelar: {0}" -f $DeadManTaskName); exit 1
  }
  $trRun = ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Run -Generation {1} -StateRoot "{2}" -GatewayTask "{3}" -WatchdogTask "{4}" -HealthUrl {6} -PhaseTimeoutSec {7} -GlobalTimeoutSec {8} -ProbeTimeoutSec {9} -LockTimeoutSec {10} -RecoverTimeoutSec {16} -PayloadScript "{11}" -PayloadSha256 {12} -OpenClawVersion {13} -SourceSha {14} -HostName "{15}"' -f $self, $gen, $root, $GatewayTask, $WatchdogTask, $DeadManTaskName, $HealthUrl, $PhaseTimeoutSec, $GlobalTimeoutSec, $ProbeTimeoutSec, $LockTimeoutSec, $PayloadScript, $payloadSha, $OpenClawVersion, $SourceSha, $hostName, $RecoverTimeoutSec)
  $trDead = ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -DeadMan -Generation {1} -StateRoot "{2}" -GatewayTask "{3}" -WatchdogTask "{4}" -HealthUrl {6} -ProbeTimeoutSec {9} -LockTimeoutSec {10} -RecoverTimeoutSec {16} -DeadManWaitSec {17} -HeartbeatStaleSec {18} -OpenClawVersion {13} -SourceSha {14} -HostName "{15}"' -f $self, $gen, $root, $GatewayTask, $WatchdogTask, $DeadManTaskName, $HealthUrl, $PhaseTimeoutSec, $GlobalTimeoutSec, $ProbeTimeoutSec, $LockTimeoutSec, $PayloadScript, $payloadSha, $OpenClawVersion, $SourceSha, $hostName, $RecoverTimeoutSec, $DeadManWaitSec, $HeartbeatStaleSec)
  $createdRun = $false
  $createdDead = $false
  try {
    [void](Invoke-CutoverSchtasks -Step 'crear one-shot' -SchtasksArgs @('/create', '/tn', $TaskName, '/tr', $trRun, '/sc', 'once', '/st', $backstopLocal.ToString('HH:mm'), '/sd', $backstopLocal.ToString('MM\/dd\/yyyy'), '/f'))
    $createdRun = $true
    [void](Invoke-CutoverSchtasks -Step 'crear dead-man' -SchtasksArgs @('/create', '/tn', $DeadManTaskName, '/tr', $trDead, '/sc', 'once', '/st', $dmLocal.ToString('HH:mm'), '/sd', $dmLocal.ToString('MM\/dd\/yyyy'), '/f'))
    $createdDead = $true
  } catch {
    foreach ($t in @($TaskName, $DeadManTaskName)) {
      & schtasks /delete /tn $t /f 2>&1 | Out-Null
    }
    Write-Output ("dispatch: {0}" -f (Remove-SecretValue -Text $_.Exception.Message))
    exit 1
  }
  $lease = [ordered]@{
    schema = 'cutover-lease.v1'; generation = $gen
    createdAt = (Format-CutoverUtc -Instant $nowUtc)
    expiresAt = (Format-CutoverUtc -Instant $expUtc)
    statePath = $statePath; taskName = $TaskName
    deadManTaskName = $DeadManTaskName
    deadManFireTimeUtc = (Format-CutoverUtc -Instant $dmUtc)
    issuedBy = $hostName
  }
  $leaseJson = (New-Object PSObject -Property $lease) | ConvertTo-Json -Depth 5 -Compress
  $state = [ordered]@{
    schema = 'cutover-state.v1'; generation = $gen; status = 'IN_PROGRESS'
    completedPhases = @(); updatedAt = (Format-CutoverUtc -Instant $nowUtc); attempts = 0
  }
  $stateJson = (New-Object PSObject -Property $state) | ConvertTo-Json -Depth 5 -Compress
  if (-not (Test-CutoverLeaseObject -LeaseJson $leaseJson)) {
    & schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
    & schtasks /delete /tn $DeadManTaskName /f 2>&1 | Out-Null
    Write-Output 'dispatch: lease generado invalido'; exit 1
  }
  if (-not (Test-CutoverStateObject -StateJson $stateJson)) {
    & schtasks /delete /tn $TaskName /f 2>&1 | Out-Null
    & schtasks /delete /tn $DeadManTaskName /f 2>&1 | Out-Null
    Write-Output 'dispatch: estado generado invalido'; exit 1
  }
  Write-CutoverTextAtomic -Content $leaseJson -Path $leasePath
  Write-CutoverTextAtomic -Content $stateJson -Path $statePath
  & schtasks /run /tn $TaskName 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Output 'aviso: /run del one-shot fallo, dispara por backstop /st'
  }
  Write-Output ("generation={0}" -f $gen)
  Write-Output ("receipt={0}" -f $receiptPath)
  Write-Output ("state={0}" -f $statePath)
  exit 0
}

if ($Run) {
  $root = Resolve-CutoverRoot -Wanted $StateRoot
  $hostName = Resolve-CutoverHost -Wanted $HostName
  if ($Generation -eq '') { Write-Output 'run: Generation vacio'; exit 1 }
  $gen = $Generation
  $logPath = Join-Path (Join-Path $root 'logs') ("cutover-{0}.log" -f $gen)
  $lockPath = Join-Path $root 'state.lock'
  $commands = New-Object System.Collections.ArrayList
  $observations = New-Object System.Collections.ArrayList
  $startedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
  $globalDeadline = [DateTime]::UtcNow.AddSeconds($GlobalTimeoutSec)
  $myAttempt = 0
  try {
    $pair0 = Read-CutoverPair -StateRoot $root
  } catch {
    Write-Output ("run: {0}" -f (Remove-SecretValue -Text $_.Exception.Message)); exit 1
  }
  if ($pair0.state.generation -cne $gen) { Write-Output 'run: generacion ajena al estado'; exit 1 }
  if ($pair0.state.status -ceq 'DONE') {
    Write-CutoverLog -LogPath $logPath -Text ("terminal=DONE generation={0} (ya terminal, sin accion)" -f $gen)
    exit 0
  }
  if ($pair0.state.status -ceq 'ROLLED_BACK') {
    Write-Output ("terminal=ROLLED_BACK generation={0} (terminal: re-despachar, no re-correr)" -f $gen)
    exit 1
  }
  if (-not (Test-CutoverLease -StateRoot $root -ExpectedGeneration $gen)) {
    Write-Output 'run: lease invalido para esta generacion'; exit 1
  }
  if (-not (Test-CutoverAbsolutePath -Path $PayloadScript)) { Write-Output 'run: PayloadScript no absoluto'; exit 1 }
  if (-not (Test-HashEqual -Path $PayloadScript -ExpectedSha256 $PayloadSha256)) {
    Write-Output 'run: payload cambio desde dispatch (hash distinto)'; exit 1
  }
  if ($RecoverTimeoutSec -le 0) { Write-Output 'run: RecoverTimeoutSec positivo'; exit 1 }
  $receiptSchema = Get-CutoverReceiptSchemaPath
  if (-not (Test-Path -LiteralPath $receiptSchema)) { Write-Output 'run: schema de recibo ilegible'; exit 1 }
  $fs0 = $null
  try {
    $fs0 = Lock-CutoverState -LockPath $lockPath -TimeoutSec $LockTimeoutSec
    $pairA = Read-CutoverPair -StateRoot $root
    if ($pairA.state.generation -cne $gen) { throw 'generacion ajena al estado' }
    if ($pairA.state.status -cne 'IN_PROGRESS') { throw ("terminal ajeno: {0}" -f $pairA.state.status) }
    $myAttempt = $pairA.state.attempts + 1
    $pairA.state.attempts = $myAttempt
    $pairA.state.updatedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
    $sjA = ($pairA.state | ConvertTo-Json -Depth 5 -Compress)
    if (-not (Test-CutoverStateObject -StateJson $sjA)) { throw 'intento regenerado invalido' }
    Write-CutoverTextAtomic -Content $sjA -Path $pairA.lease.statePath
  } catch {
    Write-Output ("run: {0}" -f (Remove-SecretValue -Text $_.Exception.Message)); exit 1
  } finally {
    if ($null -ne $fs0) { $fs0.Close() }
  }
  $leaseNow = (Read-CutoverPair -StateRoot $root).lease
  $dmName = $leaseNow.deadManTaskName
  $rbArtifact = "scheduled-task:{0}" -f $dmName
  $rbDeadline = Format-CutoverUtc -Instant $leaseNow.deadManFireTimeUtc
  $inputs = [ordered]@{
    payloadScript = [ordered]@{ algo = 'sha256'; sha256 = $PayloadSha256.ToLowerInvariant() }
    lease = [ordered]@{ algo = 'sha256'; sha256 = ((Get-FileHash -LiteralPath (Join-Path $root 'lease.json') -Algorithm SHA256).Hash.ToLowerInvariant()) }
  }
  $health = [ordered]@{ startupz = 0; readyz = 0 }
  $doneNow = @((Read-CutoverPair -StateRoot $root).state.completedPhases)
  $failMsg = ''
  $succeeded = $false
  $stopDone = ($doneNow -contains 'stop')
  try {
    if ($doneNow -notcontains 'stop') {
      Assert-CutoverAlive -Rt $root -Gen $gen -MyAttempt $myAttempt -GlobalDeadline $globalDeadline -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
      Write-CutoverLog -LogPath $logPath -Text 'fase=stop inicio'
      $phaseDeadline = [DateTime]::UtcNow.AddSeconds($PhaseTimeoutSec)
      [void](Invoke-CutoverStep -Step 'watchdog-disable' -SchtasksArgs @('/change', '/tn', $WatchdogTask, '/disable') -Commands $commands)
      $gwStatus = Get-CutoverTaskStatus -Name $GatewayTask
      if ($gwStatus -ceq 'Running') {
        [void](Invoke-CutoverStep -Step 'gateway-end' -SchtasksArgs @('/end', '/tn', $GatewayTask) -Commands $commands)
      } else {
        Add-CutoverObservation -List $observations -Text 'stop: gateway ya detenido'
      }
      while ($true) {
        Assert-CutoverAlive -Rt $root -Gen $gen -MyAttempt $myAttempt -GlobalDeadline $globalDeadline -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
        $hs = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
        if ($hs['startupz'] -eq 0 -and $hs['readyz'] -eq 0) { break }
        if ([DateTime]::UtcNow -ge $phaseDeadline) { throw 'stop: gateway sigue sirviendo tras fase' }
        Start-Sleep -Seconds 2
      }
      [void]$commands.Add([PSCustomObject]@{ name = 'probes-stop'; exit = 0 })
      Add-CutoverObservation -List $observations -Text 'stop: gateway detenido verificado'
      Complete-CutoverPhase -Rt $root -Gen $gen -MyAttempt $myAttempt -Phase 'stop' -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
      $stopDone = $true
      Write-CutoverLog -LogPath $logPath -Text 'fase=stop ok'
    } else {
      Add-CutoverObservation -List $observations -Text 'stop: ya completa (reanudacion)'
    }
    if ($doneNow -notcontains 'payload') {
      Assert-CutoverAlive -Rt $root -Gen $gen -MyAttempt $myAttempt -GlobalDeadline $globalDeadline -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
      Write-CutoverLog -LogPath $logPath -Text 'fase=payload inicio'
      $phaseDeadline = [DateTime]::UtcNow.AddSeconds($PhaseTimeoutSec)
      $job = Start-Job -ScriptBlock { param($p) & $p; ('PAYLOAD-EXIT:' + $LASTEXITCODE) } -ArgumentList $PayloadScript
      $timedOut = $false
      $jobReaped = $false
      try {
        while ($true) {
          $w = Wait-Job $job -Timeout 5
          if ($null -ne $w) { break }
          Assert-CutoverAlive -Rt $root -Gen $gen -MyAttempt $myAttempt -GlobalDeadline $globalDeadline -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
          if (([DateTime]::UtcNow -ge $phaseDeadline) -or ([DateTime]::UtcNow -ge $globalDeadline)) {
            $timedOut = $true
            Stop-Job $job
            break
          }
        }
        if ($timedOut) {
          Remove-Job $job -Force
          $jobReaped = $true
          [void]$commands.Add([PSCustomObject]@{ name = 'payload'; exit = 124 })
          throw 'payload excedio su plazo'
        }
        $texts = @()
        try { $texts = @(Receive-Job $job -ErrorAction Stop) } catch { $texts = @($_.Exception.Message) }
        $jobFailed = ($job.State -eq 'Failed')
        Remove-Job $job -Force
        $jobReaped = $true
        $exitMark = ''
        if (-not $jobFailed) {
          $mm = [regex]::Match(($texts | Out-String), '(?m)^PAYLOAD-EXIT:(.*)$')
          if ($mm.Success) { $exitMark = $mm.Groups[1].Value.Trim() } else { $exitMark = 'SIN-MARCA' }
          if ($exitMark -ne '' -and $exitMark -ne '0') { $jobFailed = $true }
        }
        foreach ($t in (($texts | Out-String) -split "`r?`n")) {
          $s = $t.Trim()
          if ($s -ne '' -and $s -notmatch '^PAYLOAD-EXIT:') {
            Add-CutoverObservation -List $observations -Text ("payload: {0}" -f $s)
            Write-CutoverLog -LogPath $logPath -Text ("payload: {0}" -f $s)
          }
        }
        if ($jobFailed) {
          $payExit = 1
          if ($exitMark -match '^\d+$') { $payExit = [int]$exitMark }
          [void]$commands.Add([PSCustomObject]@{ name = 'payload'; exit = $payExit })
          throw ("payload fallo (exit={0})" -f $exitMark)
        }
      } finally {
        if (-not $jobReaped) {
          Stop-Job $job -ErrorAction SilentlyContinue
          Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
      }
      Add-CutoverObservation -List $observations -Text 'payload: exit 0'
      [void]$commands.Add([PSCustomObject]@{ name = 'payload'; exit = 0 })
      Complete-CutoverPhase -Rt $root -Gen $gen -MyAttempt $myAttempt -Phase 'payload' -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
      Write-CutoverLog -LogPath $logPath -Text 'fase=payload ok'
    } else {
      Add-CutoverObservation -List $observations -Text 'payload: ya completa (reanudacion)'
    }
    if ($doneNow -notcontains 'restart') {
      Assert-CutoverAlive -Rt $root -Gen $gen -MyAttempt $myAttempt -GlobalDeadline $globalDeadline -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
      Write-CutoverLog -LogPath $logPath -Text 'fase=restart inicio'
      $phaseDeadline = [DateTime]::UtcNow.AddSeconds($PhaseTimeoutSec)
      $gwStatus2 = Get-CutoverTaskStatus -Name $GatewayTask
      if ($gwStatus2 -cne 'Running') {
        [void](Invoke-CutoverStep -Step 'gateway-run' -SchtasksArgs @('/run', '/tn', $GatewayTask) -Commands $commands)
      } else {
        Add-CutoverObservation -List $observations -Text 'restart: gateway ya corriendo'
      }
      while ($true) {
        Assert-CutoverAlive -Rt $root -Gen $gen -MyAttempt $myAttempt -GlobalDeadline $globalDeadline -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
        $hr = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
        if ($hr['startupz'] -eq 200 -and $hr['readyz'] -eq 200) { $health = $hr; break }
        if ([DateTime]::UtcNow -ge $phaseDeadline) { throw 'restart: salud sin verde tras fase' }
        Start-Sleep -Seconds 2
      }
      [void]$commands.Add([PSCustomObject]@{ name = 'probes-restart'; exit = 0 })
      Add-CutoverObservation -List $observations -Text 'restart: 200/200 verificado'
      Complete-CutoverPhase -Rt $root -Gen $gen -MyAttempt $myAttempt -Phase 'restart' -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
      Write-CutoverLog -LogPath $logPath -Text 'fase=restart ok'
    } else {
      Add-CutoverObservation -List $observations -Text 'restart: ya completa (reanudacion)'
    }
    Assert-CutoverAlive -Rt $root -Gen $gen -MyAttempt $myAttempt -GlobalDeadline $globalDeadline -LockPath $lockPath -LockTimeoutSec $LockTimeoutSec
    Write-CutoverLog -LogPath $logPath -Text 'fase=finalize inicio'
    [void](Invoke-CutoverStep -Step 'watchdog-enable' -SchtasksArgs @('/change', '/tn', $WatchdogTask, '/enable') -Commands $commands)
    $hf = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
    if ($hf['startupz'] -ne 200 -or $hf['readyz'] -ne 200) { throw 'finalize: salud sin verde tras re-enable' }
    $health = $hf
    [void]$commands.Add([PSCustomObject]@{ name = 'probes-finalize'; exit = 0 })
    $fsT = $null
    try {
      $fsT = Lock-CutoverState -LockPath $lockPath -TimeoutSec $LockTimeoutSec
      $pairT = Read-CutoverPair -StateRoot $root
      if ($pairT.state.generation -cne $gen) { throw 'generacion ajena al estado' }
      if ($pairT.state.status -cne 'IN_PROGRESS') { throw ("terminal ajeno: {0}" -f $pairT.state.status) }
      if ($pairT.state.attempts -ne $myAttempt) { throw 'run desplazado por otro intento' }
      $pairT.state.status = 'DONE'
      $pairT.state.completedPhases = @('stop', 'payload', 'restart', 'finalize')
      $pairT.state.updatedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
      $sjT = ($pairT.state | ConvertTo-Json -Depth 5 -Compress)
      if (-not (Test-CutoverStateObject -StateJson $sjT)) { throw 'DONE regenerado invalido' }
      Write-CutoverTextAtomic -Content $sjT -Path $pairT.lease.statePath
      Add-CutoverObservation -List $observations -Text 'finalize: DONE escrito'
      Write-CutoverReceipt -Rt $root -Gen $gen -Result 'passed' -Health $health -Commands $commands.ToArray() -Inputs $inputs -Observations $observations.ToArray() -Artifact $rbArtifact -DeadlineUtc $rbDeadline -StartedAt $startedAt -SrcSha $SourceSha -HostName $hostName -Version $OpenClawVersion -SchemaPath $receiptSchema
    } finally {
      if ($null -ne $fsT) { $fsT.Close() }
    }
    & schtasks /delete /tn $dmName /f 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-CutoverLog -LogPath $logPath -Text 'aviso: /delete del dead-man fallo (inofensivo: ve DONE y sale)'
    }
    $succeeded = $true
  } catch {
    $failMsg = Remove-SecretValue -Text $_.Exception.Message
    Write-CutoverLog -LogPath $logPath -Text ("fallo: {0}" -f $failMsg)
  } finally {
    if (-not $succeeded) {
      $recHealth = [ordered]@{ startupz = 0; readyz = 0 }
      $recovered = $false
      try {
        $h0 = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
        if ($h0['startupz'] -eq 200 -and $h0['readyz'] -eq 200) {
          $recHealth = $h0
          $recovered = $true
          Add-CutoverObservation -List $observations -Text 'recuperacion: gateway ya sano'
        } else {
          $st = ''
          try { $st = Get-CutoverTaskStatus -Name $GatewayTask } catch { $st = 'desconocido' }
          if ($st -cne 'Running') {
            & schtasks /run /tn $GatewayTask 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
              [void]$commands.Add([PSCustomObject]@{ name = 'gateway-run-recuperacion'; exit = 0 })
            } else {
              Add-CutoverObservation -List $observations -Text 'recuperacion: /run fallo'
            }
          }
          $recDeadline = [DateTime]::UtcNow.AddSeconds($RecoverTimeoutSec)
          while ([DateTime]::UtcNow -lt $recDeadline) {
            $h1 = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
            $recHealth = $h1
            if ($h1['startupz'] -eq 200 -and $h1['readyz'] -eq 200) { $recovered = $true; break }
            Start-Sleep -Seconds 2
          }
          if (-not $recovered) { Add-CutoverObservation -List $observations -Text 'recuperacion: salud sin verde' }
        }
        & schtasks /change /tn $WatchdogTask /enable 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
          [void]$commands.Add([PSCustomObject]@{ name = 'watchdog-enable-recuperacion'; exit = 0 })
        } elseif ($stopDone) {
          Add-CutoverObservation -List $observations -Text 'recuperacion: re-enable fallo'
          $recovered = $false
        } else {
          Add-CutoverObservation -List $observations -Text 'recuperacion: re-enable innecesario (stop no corrio)'
        }
      } catch {
        Add-CutoverObservation -List $observations -Text ("recuperacion: {0}" -f (Remove-SecretValue -Text $_.Exception.Message))
      }
      Add-CutoverObservation -List $observations -Text ("fallo: {0}" -f $failMsg)
      $fs2 = $null
      $terminalEscrito = ''
      try {
        $fs2 = Lock-CutoverState -LockPath $lockPath -TimeoutSec $LockTimeoutSec
        $pair2 = Read-CutoverPair -StateRoot $root
        if ($pair2.state.generation -cne $gen) { throw 'generacion ajena al estado' }
        if ($pair2.state.status -cne 'IN_PROGRESS') {
          $terminalEscrito = $pair2.state.status
        } elseif ($pair2.state.attempts -ne $myAttempt) {
          $terminalEscrito = 'DESPLAZADO'
        } elseif ($recovered) {
          $pair2.state.status = 'ROLLED_BACK'
          $pair2.state.updatedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
          $sj2 = ($pair2.state | ConvertTo-Json -Depth 5 -Compress)
          if (-not (Test-CutoverStateObject -StateJson $sj2)) { throw 'ROLLED_BACK regenerado invalido' }
          Write-CutoverTextAtomic -Content $sj2 -Path $pair2.lease.statePath
          Write-CutoverReceipt -Rt $root -Gen $gen -Result 'rolled_back' -Health $recHealth -Commands $commands.ToArray() -Inputs $inputs -Observations $observations.ToArray() -Artifact $rbArtifact -DeadlineUtc $rbDeadline -StartedAt $startedAt -SrcSha $SourceSha -HostName $hostName -Version $OpenClawVersion -SchemaPath $receiptSchema
          $terminalEscrito = 'ROLLED_BACK'
        } else {
          Write-CutoverReceipt -Rt $root -Gen $gen -Result 'failed' -Health $recHealth -Commands $commands.ToArray() -Inputs $inputs -Observations $observations.ToArray() -Artifact $rbArtifact -DeadlineUtc $rbDeadline -StartedAt $startedAt -SrcSha $SourceSha -HostName $hostName -Version $OpenClawVersion -SchemaPath $receiptSchema
          $terminalEscrito = 'FAILED SIN TERMINAL'
        }
      } catch {
        $terminalEscrito = 'ERROR: ' + (Remove-SecretValue -Text $_.Exception.Message)
      } finally {
        if ($null -ne $fs2) { $fs2.Close() }
      }
      Write-CutoverLog -LogPath $logPath -Text ("terminal={0} generation={1}" -f $terminalEscrito, $gen)
    }
  }
  if ($succeeded) {
    Write-CutoverLog -LogPath $logPath -Text ("terminal=DONE generation={0}" -f $gen)
    exit 0
  }
  exit 1
}

if ($DeadMan) {
  $root = Resolve-CutoverRoot -Wanted $StateRoot
  $hostName = Resolve-CutoverHost -Wanted $HostName
  if ($Generation -eq '') { Write-Output 'deadman: Generation vacio'; exit 1 }
  if ($RecoverTimeoutSec -le 0 -or $DeadManWaitSec -le 0 -or $HeartbeatStaleSec -le 0 -or $ProbeTimeoutSec -le 0 -or $LockTimeoutSec -le 0) {
    Write-Output 'deadman: plazos positivos'; exit 1
  }
  $gen = $Generation
  $logPath = Join-Path (Join-Path $root 'logs') ("cutover-{0}.log" -f $gen)
  $lockPath = Join-Path $root 'state.lock'
  $commands = New-Object System.Collections.ArrayList
  $observations = New-Object System.Collections.ArrayList
  $startedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
  $receiptSchema = Get-CutoverReceiptSchemaPath
  if (-not (Test-Path -LiteralPath $receiptSchema)) { Write-Output 'deadman: schema de recibo ilegible'; exit 1 }
  $fsD = $null
  $dl = $null
  try {
    $fsD = Lock-CutoverState -LockPath $lockPath -TimeoutSec $LockTimeoutSec
    try {
      $pairD = Read-CutoverPair -StateRoot $root
    } catch {
      Write-CutoverLog -LogPath $logPath -Text ("deadman: {0} (sin accion)" -f (Remove-SecretValue -Text $_.Exception.Message))
      exit 1
    }
    $dl = $pairD.lease
    if ($pairD.state.generation -cne $gen -or $dl.generation -cne $gen) {
      Write-CutoverLog -LogPath $logPath -Text ("deadman: generacion ajena (estado {0}, sin accion)" -f $pairD.state.generation)
      exit 0
    }
    if ($pairD.state.status -ceq 'DONE') {
      Write-CutoverLog -LogPath $logPath -Text ("terminal=DONE generation={0} (ya terminal, sin accion)" -f $gen)
      exit 0
    }
    if ($pairD.state.status -ceq 'ROLLED_BACK') {
      Write-CutoverLog -LogPath $logPath -Text ("terminal=ROLLED_BACK generation={0} (ya terminal, sin accion)" -f $gen)
      exit 0
    }
  } finally {
    if ($null -ne $fsD) { $fsD.Close(); $fsD = $null }
  }
  $rbArtifact = "scheduled-task:{0}" -f $dl.deadManTaskName
  $rbDeadline = Format-CutoverUtc -Instant $dl.deadManFireTimeUtc
  $inputsD = [ordered]@{
    lease = [ordered]@{ algo = 'sha256'; sha256 = ((Get-FileHash -LiteralPath (Join-Path $root 'lease.json') -Algorithm SHA256).Hash.ToLowerInvariant()) }
  }
  $waitDeadline = [DateTime]::UtcNow.AddSeconds($DeadManWaitSec)
  $avisado = $false
  $colgado = $false
  while ($true) {
    $fsW = $null
    $staleNow = $true
    try {
      $fsW = Lock-CutoverState -LockPath $lockPath -TimeoutSec $LockTimeoutSec
      $pW = Read-CutoverPair -StateRoot $root
      if ($pW.state.generation -cne $gen -or $pW.lease.generation -cne $gen) {
        Write-CutoverLog -LogPath $logPath -Text 'deadman: generacion ajena al releer (sin accion)'
        exit 0
      }
      if ($pW.state.status -cne 'IN_PROGRESS') {
        Write-CutoverLog -LogPath $logPath -Text ("terminal={0} generation={1} (run termino solo, sin accion)" -f $pW.state.status, $gen)
        exit 0
      }
      $age = ([DateTime]::UtcNow - $pW.state.updatedAt.ToUniversalTime()).TotalSeconds
      $staleNow = ($age -gt $HeartbeatStaleSec)
    } finally {
      if ($null -ne $fsW) { $fsW.Close() }
    }
    if ($staleNow) { break }
    if ([DateTime]::UtcNow -ge $waitDeadline) { $colgado = $true; break }
    if (-not $avisado) {
      Write-CutoverLog -LogPath $logPath -Text 'deadman: run vivo, esperando'
      $avisado = $true
    }
    Start-Sleep -Seconds 2
  }
  if ($colgado) {
    Write-CutoverLog -LogPath $logPath -Text 'deadman: run colgado tras espera; terminando one-shot'
    & schtasks /end /tn $dl.taskName 2>&1 | Out-Null
    [void]$commands.Add([PSCustomObject]@{ name = 'one-shot-end'; exit = $LASTEXITCODE })
    Start-Sleep -Seconds ($HeartbeatStaleSec + 1)
    $fsC = $null
    try {
      $fsC = Lock-CutoverState -LockPath $lockPath -TimeoutSec $LockTimeoutSec
      $pC = Read-CutoverPair -StateRoot $root
      if ($pC.state.status -cne 'IN_PROGRESS' -or $pC.state.generation -cne $gen) {
        Write-CutoverLog -LogPath $logPath -Text ("terminal={0} generation={1} (sin accion)" -f $pC.state.status, $gen)
        exit 0
      }
      $ageC = ([DateTime]::UtcNow - $pC.state.updatedAt.ToUniversalTime()).TotalSeconds
      if ($ageC -le $HeartbeatStaleSec) {
        Add-CutoverObservation -List $observations -Text 'run colgado sigue latiendo tras /end'
        $hC = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
        Write-CutoverReceipt -Rt $root -Gen $gen -Result 'failed' -Health $hC -Commands $commands.ToArray() -Inputs $inputsD -Observations $observations.ToArray() -Artifact $rbArtifact -DeadlineUtc $rbDeadline -StartedAt $startedAt -SrcSha $SourceSha -HostName $hostName -Version $OpenClawVersion -SchemaPath $receiptSchema
        Write-CutoverLog -LogPath $logPath -Text ("terminal=FAILED SIN TERMINAL generation={0}" -f $gen)
        exit 1
      }
      Write-CutoverLog -LogPath $logPath -Text 'deadman: run colgado terminado'
    } finally {
      if ($null -ne $fsC) { $fsC.Close() }
    }
  }
  $fsR = $null
  try {
    $fsR = Lock-CutoverState -LockPath $lockPath -TimeoutSec $LockTimeoutSec
    $pR = Read-CutoverPair -StateRoot $root
    if ($pR.state.generation -cne $gen -or $pR.lease.generation -cne $gen) {
      Write-CutoverLog -LogPath $logPath -Text 'deadman: generacion ajena al recuperar (sin accion)'
      exit 0
    }
    if ($pR.state.status -cne 'IN_PROGRESS') {
      Write-CutoverLog -LogPath $logPath -Text ("terminal={0} generation={1} (sin accion)" -f $pR.state.status, $gen)
      exit 0
    }
    try {
      $recHealth = [ordered]@{ startupz = 0; readyz = 0 }
      $stR = Get-CutoverTaskStatus -Name $GatewayTask -Commands $commands
      if ($stR -cne 'Running') {
        [void](Invoke-CutoverStep -Step 'gateway-run' -SchtasksArgs @('/run', '/tn', $GatewayTask) -Commands $commands)
      } else {
        Add-CutoverObservation -List $observations -Text 'recuperacion: gateway ya corriendo'
      }
      $recDeadline = [DateTime]::UtcNow.AddSeconds($RecoverTimeoutSec)
      $sano = $false
      while ([DateTime]::UtcNow -lt $recDeadline) {
        $hR = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
        if ($hR['startupz'] -eq 200 -and $hR['readyz'] -eq 200) { $recHealth = $hR; $sano = $true; break }
        Start-Sleep -Seconds 2
      }
      if (-not $sano) { throw 'recuperacion: salud sin verde' }
      [void]$commands.Add([PSCustomObject]@{ name = 'probes-recuperacion'; exit = 0 })
      [void](Invoke-CutoverStep -Step 'watchdog-enable' -SchtasksArgs @('/change', '/tn', $WatchdogTask, '/enable') -Commands $commands)
      $pR.state.status = 'ROLLED_BACK'
      $pR.state.updatedAt = Format-CutoverUtc -Instant ([DateTime]::UtcNow)
      $sjR = ($pR.state | ConvertTo-Json -Depth 5 -Compress)
      if (-not (Test-CutoverStateObject -StateJson $sjR)) { throw 'ROLLED_BACK regenerado invalido' }
      Write-CutoverTextAtomic -Content $sjR -Path $pR.lease.statePath
      Add-CutoverObservation -List $observations -Text 'recuperacion: ROLLED_BACK escrito'
      Write-CutoverReceipt -Rt $root -Gen $gen -Result 'rolled_back' -Health $recHealth -Commands $commands.ToArray() -Inputs $inputsD -Observations $observations.ToArray() -Artifact $rbArtifact -DeadlineUtc $rbDeadline -StartedAt $startedAt -SrcSha $SourceSha -HostName $hostName -Version $OpenClawVersion -SchemaPath $receiptSchema
      Write-CutoverLog -LogPath $logPath -Text ("terminal=ROLLED_BACK generation={0}" -f $gen)
      exit 0
    } catch {
      $dmFail = Remove-SecretValue -Text $_.Exception.Message
      Write-CutoverLog -LogPath $logPath -Text ("deadman fallo: {0}" -f $dmFail)
      Add-CutoverObservation -List $observations -Text ("fallo: {0}" -f $dmFail)
      $hF = Get-CutoverHealth -HealthUrl $HealthUrl -ProbeTimeoutSec $ProbeTimeoutSec
      try {
        Write-CutoverReceipt -Rt $root -Gen $gen -Result 'failed' -Health $hF -Commands $commands.ToArray() -Inputs $inputsD -Observations $observations.ToArray() -Artifact $rbArtifact -DeadlineUtc $rbDeadline -StartedAt $startedAt -SrcSha $SourceSha -HostName $hostName -Version $OpenClawVersion -SchemaPath $receiptSchema
      } catch {
        Write-CutoverLog -LogPath $logPath -Text ("deadman: recibo failed no escrito: {0}" -f (Remove-SecretValue -Text $_.Exception.Message))
      }
      Write-CutoverLog -LogPath $logPath -Text ("terminal=FAILED SIN TERMINAL generation={0}" -f $gen)
      exit 1
    }
  } finally {
    if ($null -ne $fsR) { $fsR.Close() }
  }
}
