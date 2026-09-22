# Set-OpenClawNode.ps1 — alta del nodo Windows aislado (Fase 16, Task 6).
#
# Sin -Apply es report-only: valida allowlist y config, imprime el plan y no
# escribe nada. Con -Apply crea el estado aislado con ACL restringida (sin
# SQLite del gateway), aplica la config minima exacta con relectura, valida
# la allowlist local (sin comodines ni shells, argv exacto o argPattern
# anclado con casos, sin repeticion anidada), lee la identidad del
# dispositivo, aplica y relee la allowlist sobre esa identidad, y SOLO
# entonces empareja una vez en primer plano con `node run --pair` (el
# codigo jamas se registra), aprueba el dispositivo pre-aprobado +
# superficie exacta de 8 comandos, instala sin --pair bajo el mismo
# estado, exporta y borra la duplicada, verifica la oficial habilitada
# con logon trigger y estado aislado, reinicia y espera conexion + 2026.9.5.
# Salidas: 0 ok, 1 freno, 2 herramienta ausente.
# Produccion: -NodeStateDir C:\Users\ehven\.openclaw-node -NodeUser ehven.
param(
  [Parameter(Mandatory = $true)][string]$NodeStateDir,
  [Parameter(Mandatory = $true)][string]$NodeDisplayName,
  [Parameter(Mandatory = $true)][string]$GatewayHost,
  [int]$GatewayPort = 18789,
  [string]$TlsFingerprint = '',
  [switch]$NoTls,
  [Parameter(Mandatory = $true)][string]$ApprovalsPath,
  [string[]]$NodeConfigSets = @(),
  [string]$PairingCode = '',
  [string]$NodeTaskName = 'OpenClaw Node',
  [string]$DuplicateTaskName = 'OpenClaw CUA Node',
  [string]$NodeUser = '',
  [string]$TaskExportDir = '',
  [Parameter(Mandatory = $true)][string]$ReceiptRoot,
  [int]$PairTimeoutSec = 300,
  [int]$StatusTimeoutSec = 300,
  [int]$PollIntervalSec = 5,
  [string]$HealthUrl = 'http://127.0.0.1:18789',
  [string]$OpenClawVersion = '',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeSeparation.psm1') -Force

# CLI (-File) no arma arrays: aceptar elementos unidos con ';'.
$NodeConfigSets = @($NodeConfigSets | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })

$WANT_COMMANDS = @('browser.proxy', 'browser.proxy.upload.v1', 'computer.act',
  'screen.snapshot', 'system.run', 'system.run.prepare', 'system.which', 'fs.listDir')
$BLOCKED_EXE = @('sh', 'bash', 'dash', 'zsh', 'fish', 'ksh', 'powershell', 'pwsh',
  'cmd', 'wscript', 'cscript', 'python', 'python3', 'node', 'bun', 'deno', 'perl', 'ruby', 'php')

function Get-UtcNow { return ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) }
function Get-FileSha([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-ResolvedVersion([string]$Pinned) {
  if (-not [string]::IsNullOrEmpty($Pinned)) { return $Pinned }
  $v = (& openclaw --version 2>&1 | Out-String)
  $m = [regex]::Match($v, '(\d{4}\.\d+\.\d+)')
  if (-not $m.Success) { throw 'version openclaw irresoluble' }
  return $m.Groups[1].Value
}
function ConvertTo-CanonicalJson($Obj) {
  if ($null -eq $Obj) { return 'null' }
  if ($Obj -is [string]) {
    return ('"' + $Obj.Replace('\', '\\').Replace('"', '\"') + '"')
  }
  if ($Obj -is [bool]) {
    if ($Obj) { return 'true' } else { return 'false' }
  }
  if ($Obj -is [ValueType]) { return [string]$Obj }
  if ($Obj -is [System.Collections.IEnumerable]) {
    $parts = @()
    foreach ($x in $Obj) { $parts += (ConvertTo-CanonicalJson $x) }
    return ('[' + ($parts -join ',') + ']')
  }
  $parts = @()
  foreach ($p in ($Obj.PSObject.Properties | Sort-Object Name)) {
    $parts += ((ConvertTo-CanonicalJson $p.Name) + ':' + (ConvertTo-CanonicalJson $p.Value))
  }
  return ('{' + ($parts -join ',') + '}')
}
function Read-Approvals([string]$Path) {
  $doc = $null
  try { $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 32 } catch { $doc = $null }
  if ($null -eq $doc) { throw 'allowlist ilegible' }
  if ($doc.version -ne 1) { throw 'allowlist sin version 1' }
  $agents = @($doc.agents.PSObject.Properties)
  if ($agents.Count -eq 0) { throw 'allowlist sin agentes' }
  $cases = @($doc.'x-cases')
  foreach ($ap in $agents) {
    $entries = @($ap.Value.allowlist)
    if ($entries.Count -eq 0) { throw ("allowlist vacia: {0}" -f $ap.Name) }
    foreach ($e in $entries) {
      $pat = [string]$e.pattern
      if ([string]::IsNullOrEmpty($pat)) { throw 'entrada sin pattern' }
      if ($pat -match '[*?\[\]]') { throw ("comodin: {0}" -f $pat) }
      $base = $pat -replace '^.*[\\/]', ''
      $stem = $base -replace '\.exe$', ''
      if ($BLOCKED_EXE -contains $stem.ToLowerInvariant()) { throw ("interprete: {0}" -f $pat) }
      if ($base -match '\.(ps1|sh|bat|cmd|vbs|js)$') { throw ("script: {0}" -f $pat) }
      $argp = $e.argPattern
      if ($null -eq $argp -or ([string]$argp) -eq '') { throw ("path-only: {0}" -f $pat) }
      $argp = [string]$argp
      if ($argp[0] -cne '^' -or $argp[$argp.Length - 1] -cne '$') {
        throw ("sin anclar: {0}" -f $pat)
      }
      if ($argp -match '\([^()]*[*+?][^()]*\)[*+?]') {
        throw ("repeticion anidada: {0}" -f $pat)
      }
      $rx = $null
      try {
        $rx = New-Object System.Text.RegularExpressions.Regex($argp,
          ([System.Text.RegularExpressions.RegexOptions]::ECMAScript -bor
           [System.Text.RegularExpressions.RegexOptions]::CultureInvariant))
      } catch {
        throw ("regex invalido: {0}" -f $pat)
      }
      $cb = @($cases | Where-Object { $_.pattern -ceq $pat -and $_.argPattern -ceq $argp })
      if ($cb.Count -eq 0) { throw ("sin casos: {0}" -f $pat) }
      if (@($cb[0].allow).Count -eq 0 -or @($cb[0].deny).Count -eq 0) {
        throw ("casos vacios: {0}" -f $pat)
      }
      foreach ($c in @($cb[0].allow)) {
        if (-not $rx.IsMatch([string]$c)) { throw ("allow no casa: {0} <- {1}" -f $pat, $c) }
      }
      foreach ($c in @($cb[0].deny)) {
        if ($rx.IsMatch([string]$c)) { throw ("deny casa: {0} <- {1}" -f $pat, $c) }
      }
    }
  }
  return $doc
}

$startedAt = Get-UtcNow
$commands = New-Object System.Collections.Generic.List[object]
$observations = New-Object System.Collections.Generic.List[string]
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$failed = $false
$failWhy = ''
$inputs = [ordered]@{}
$h = @{ startupz = 0; readyz = 0 }
$rbArtifact = 'none'
$runProc = $null

try {
  $ver = ''
  try {
    $ver = Get-ResolvedVersion -Pinned $OpenClawVersion
  } catch {
    if ($Apply) {
      Write-Output 'FALLO: openclaw --version fallo'
      exit 2
    }
    $ver = 'irresoluble'
  }
  if ($ver -cne '2026.9.5') {
    [void]$commands.Add([PSCustomObject]@{ name = 'version'; exit = 1 })
    if ($Apply) { throw 'se requiere openclaw 2026.9.5 para -Apply' }
    [void]$observations.Add("version $ver (se requiere 2026.9.5 para -Apply)")
  } else {
    [void]$commands.Add([PSCustomObject]@{ name = 'version'; exit = 0 })
  }

  $doc = Read-Approvals -Path $ApprovalsPath
  [void]$commands.Add([PSCustomObject]@{ name = 'allowlist-validate'; exit = 0 })
  if ($NodeConfigSets.Count -eq 0) { throw 'sin config sets declarados' }
  $sets = New-Object System.Collections.Generic.List[object]
  foreach ($s in $NodeConfigSets) {
    $eq = $s.IndexOf('=')
    if ($eq -le 0) { throw ("set sin forma path=value: {0}" -f $s) }
    $val = $s.Substring($eq + 1)
    try { [void]($val | ConvertFrom-Json -Depth 32) } catch { throw ("set sin JSON: {0}" -f $s) }
    [void]$sets.Add([PSCustomObject]@{ Path = $s.Substring(0, $eq); Value = $val })
  }

  if (-not $Apply) {
    Write-Output 'plan nodo: estado fresco + icacls + config minima exacta'
    Write-Output 'plan nodo: node identity + approvals set + readback'
    Write-Output 'plan nodo: node run --pair en primer plano (codigo redactado)'
    Write-Output 'plan nodo: nodes approve del pre-aprobado'
    Write-Output 'plan nodo: node install sin --pair bajo el mismo estado'
    Write-Output 'plan nodo: exportar+borrar duplicada, verificar oficial'
    Write-Output 'plan nodo: reinicio + connected + 2026.9.5 + 8 comandos'
    foreach ($o in $observations) { Write-Output ("plan: observacion: {0}" -f $o) }
    exit 0
  }

  foreach ($tool in @('openclaw', 'schtasks', 'icacls')) {
    if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
      Write-Output ("FALLO: herramienta ausente: {0}" -f $tool)
      exit 2
    }
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'tools'; exit = 0 })
  if ([string]::IsNullOrEmpty($PairingCode)) { throw 'apply exige -PairingCode' }

  if (-not (Test-Path -LiteralPath $ReceiptRoot)) {
    [void](New-Item -ItemType Directory -Path $ReceiptRoot -Force)
  }
  $expDir = $TaskExportDir
  if ([string]::IsNullOrEmpty($expDir)) {
    $expDir = Join-Path (Split-Path -Parent $NodeStateDir) 'task-exports'
  }
  if (Test-Path -LiteralPath $NodeStateDir) { throw 'estado existe: se exige fresco' }
  $stParent = Split-Path -Parent $NodeStateDir
  if (-not (Test-Path -LiteralPath $stParent)) { throw 'padre de estado inexistente' }

  [void](New-Item -ItemType Directory -Path $NodeStateDir -Force)
  $rbArtifact = $NodeStateDir
  $grantArgs = @($NodeStateDir, '/inheritance:r',
    '/grant:r', '*S-1-5-18:(OI)(CI)F', '/grant:r', '*S-1-5-32-544:(OI)(CI)F')
  if (-not [string]::IsNullOrEmpty($NodeUser)) {
    $grantArgs += @('/grant:r', ("{0}:(OI)(CI)F" -f $NodeUser))
  }
  & icacls @grantArgs 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'icacls lockdown fallo' }
  $aclRaw = (& icacls $NodeStateDir 2>&1 | Out-String)
  foreach ($line in ($aclRaw -split "`r?`n")) {
    if ($line -notmatch '\(') { continue }
    $okLine = ($line -match 'SYSTEM|S-1-5-18|S-1-5-32-544|Administrators|Administradores')
    if (-not $okLine -and -not [string]::IsNullOrEmpty($NodeUser)) {
      $okLine = ($line -match [regex]::Escape($NodeUser))
    }
    if (-not $okLine) { throw ("ACL abierta: {0}" -f $line.Trim()) }
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'state-acl'; exit = 0 })

  $prevState = $env:OPENCLAW_STATE_DIR
  $env:OPENCLAW_STATE_DIR = $NodeStateDir
  try {
    foreach ($s in $sets) {
      & openclaw config set $s.Path $s.Value 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw ("config set fallo: {0}" -f $s.Path) }
      $got = (& openclaw config get $s.Path --json 2>&1 | Out-String).Trim()
      if ($LASTEXITCODE -ne 0) { throw ("config get fallo: {0}" -f $s.Path) }
      if ($got -cne $s.Value) { throw ("readback distinto: {0}" -f $s.Path) }
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'config-minimal'; exit = 0 })
    $valRaw = (& openclaw config validate --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'config validate fallo' }
    $valOk = $false
    try { $valOk = (((($valRaw | Out-String) | ConvertFrom-Json -Depth 32).ok) -eq $true) } catch { $valOk = $false }
    if (-not $valOk) { throw 'config validate no-ok' }

    $gwArgs = @('--host', $GatewayHost, '--port', [string]$GatewayPort,
      '--display-name', $NodeDisplayName)
    if (-not [string]::IsNullOrEmpty($TlsFingerprint)) {
      $gwArgs += @('--tls', '--tls-fingerprint', $TlsFingerprint)
    } elseif ($NoTls) {
      $gwArgs += @('--no-tls')
    }
    $deviceId = ''
    $deadline = [DateTime]::UtcNow.AddSeconds($PairTimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
      $idRaw = (& openclaw node identity --json 2>&1)
      if ($LASTEXITCODE -eq 0) {
        $ident = $null
        try { $ident = (($idRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $ident = $null }
        if ($null -ne $ident -and -not [string]::IsNullOrEmpty($ident.deviceId)) {
          $deviceId = [string]$ident.deviceId
          break
        }
      }
      Start-Sleep -Seconds $PollIntervalSec
    }
    if ([string]::IsNullOrEmpty($deviceId)) { throw 'identidad sin persistir (timeout)' }
    [void]$commands.Add([PSCustomObject]@{ name = 'node-identity'; exit = 0 })

    $sanitized = [ordered]@{ version = 1; agents = $doc.agents }
    $sanJson = (New-Object PSObject -Property $sanitized) | ConvertTo-Json -Depth 10 -Compress
    $sanPath = Join-Path ([IO.Path]::GetTempPath()) ('approvals-node-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
      [IO.File]::WriteAllText($sanPath, $sanJson, (New-Object Text.UTF8Encoding $false))
      & openclaw approvals set --file $sanPath --node $deviceId 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'approvals set fallo' }
      [void]$commands.Add([PSCustomObject]@{ name = 'approvals-set'; exit = 0 })
      $inputs['approvals'] = [ordered]@{ algo = 'sha256'; sha256 = (Get-FileSha -Path $sanPath) }
    } finally {
      if (Test-Path -LiteralPath $sanPath) {
        Remove-Item -LiteralPath $sanPath -Force -ErrorAction SilentlyContinue
      }
    }
    $getRaw = (& openclaw approvals get --node $deviceId --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'approvals get fallo' }
    $got = $null
    try { $got = (($getRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $got = $null }
    if ($null -eq $got -or $null -eq $got.file) { throw 'approvals get sin file' }
    if ((ConvertTo-CanonicalJson $got.file.agents) -cne (ConvertTo-CanonicalJson $doc.agents)) {
      throw 'readback de approvals distinto'
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'approvals-readback'; exit = 0 })

    $runArgs = @('node', 'run', '--pair', $PairingCode) + $gwArgs
    $runProc = Start-Process -FilePath 'openclaw' -ArgumentList $runArgs `
      -NoNewWindow -PassThru
    [void]$commands.Add([PSCustomObject]@{ name = 'node-run'; exit = 0 })
    [void]$observations.Add('pairing en primer plano (codigo redactado)')

    $nodeId = ''
    $deadline = [DateTime]::UtcNow.AddSeconds($PairTimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
      $pendRaw = (& openclaw nodes pending --json 2>&1)
      if ($LASTEXITCODE -eq 0) {
        $rawPend = @()
        try { $rawPend = @(($pendRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $rawPend = @() }
        $rawPend = @($rawPend | Where-Object { $_ -ne $null })
        $reqs = @()
        if ($rawPend.Count -eq 1 -and $null -ne $rawPend[0].requests) {
          $reqs = @($rawPend[0].requests)
        } elseif ($rawPend.Count -eq 1 -and $null -ne $rawPend[0].pending) {
          $reqs = @($rawPend[0].pending)
        } else {
          $reqs = $rawPend
        }
        $mine = @($reqs | Where-Object { $_.displayName -ceq $NodeDisplayName })
        if ($mine.Count -gt 1) { throw 'solicitud ambigua' }
        if ($mine.Count -eq 1) {
          $apRaw = (& openclaw nodes approve $mine[0].requestId --json 2>&1)
          if ($LASTEXITCODE -ne 0) { throw 'nodes approve fallo' }
          $ap = $null
          try { $ap = (($apRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $ap = $null }
          foreach ($k in @('nodeId', 'id')) {
            if (-not [string]::IsNullOrEmpty($nodeId)) { break }
            if ($null -ne $ap -and $null -ne $ap.$k) { $nodeId = [string]$ap.$k }
          }
          if ($null -ne $ap -and [string]::IsNullOrEmpty($nodeId) -and $null -ne $ap.node) {
            $nodeId = [string]$ap.node
          }
          if ([string]::IsNullOrEmpty($nodeId)) { throw 'approve sin nodeId' }
          if ($nodeId -cne $deviceId) { throw ("aprobado ajeno: {0}" -f $nodeId) }
          break
        }
      }
      Start-Sleep -Seconds $PollIntervalSec
    }
    if ([string]::IsNullOrEmpty($nodeId)) { throw 'pairing sin solicitud (timeout)' }
    [void]$commands.Add([PSCustomObject]@{ name = 'nodes-approve'; exit = 0 })
    [void]$observations.Add("dispositivo aprobado: $nodeId")
  } finally {
    $env:OPENCLAW_STATE_DIR = $prevState
    if ($null -ne $runProc) {
      Stop-Process -Id $runProc.Id -Force -ErrorAction SilentlyContinue
      $deadline = [DateTime]::UtcNow.AddSeconds(30)
      while ([DateTime]::UtcNow -lt $deadline) {
        $still = Get-Process -Id $runProc.Id -ErrorAction SilentlyContinue
        if ($null -eq $still) { break }
        Start-Sleep -Seconds 1
      }
      if ($null -ne (Get-Process -Id $runProc.Id -ErrorAction SilentlyContinue)) {
        throw 'node run no termina'
      }
      $runProc = $null
    }
  }

  $instArgs = @('node', 'install') + $gwArgs
  $env:OPENCLAW_STATE_DIR = $NodeStateDir
  try {
    & openclaw @instArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'node install fallo' }
  } finally {
    $env:OPENCLAW_STATE_DIR = $prevState
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'node-install'; exit = 0 })

  if (-not (Test-Path -LiteralPath $expDir)) {
    [void](New-Item -ItemType Directory -Path $expDir -Force)
  }
  $dupXml = (& schtasks /query /tn $DuplicateTaskName /xml 2>&1 | Out-String)
  if ($LASTEXITCODE -eq 0 -and $dupXml -match '<Task ') {
    $safe = ($DuplicateTaskName -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $xp = Join-Path $expDir ("task-{0}-{1}.xml" -f $safe, $stamp)
    [IO.File]::WriteAllText($xp, $dupXml, (New-Object Text.UTF8Encoding $false))
    $inputs['duplicateXml'] = [ordered]@{ algo = 'sha256'; sha256 = (Get-FileSha -Path $xp) }
    & schtasks /delete /tn $DuplicateTaskName /f 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'no se pudo borrar la duplicada' }
    & schtasks /query /tn $DuplicateTaskName /xml 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'la duplicada sigue viva' }
    [void]$commands.Add([PSCustomObject]@{ name = 'duplicate-remove'; exit = 0 })
    [void]$observations.Add("duplicada exportada y borrada: $DuplicateTaskName")
  } else {
    [void]$observations.Add("duplicada ausente (idempotente): $DuplicateTaskName")
  }

  $savedEnv = $env:OPENCLAW_STATE_DIR
  $env:OPENCLAW_STATE_DIR = $null
  try {
    $offXml = (& schtasks /query /tn $NodeTaskName /xml 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ("oficial ausente: {0}" -f $NodeTaskName) }
    if ($offXml -notmatch '<Enabled>true</Enabled>') { throw 'oficial sin Enabled' }
    if ($offXml -notmatch 'LogonTrigger') { throw 'oficial sin LogonTrigger' }
    if ($offXml -notmatch [regex]::Escape($NodeStateDir)) { throw 'oficial sin estado aislado' }
  } finally {
    $env:OPENCLAW_STATE_DIR = $savedEnv
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'official-verify'; exit = 0 })

  & schtasks /run /tn $NodeTaskName 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'reinicio de tarea fallo' }
  $up = $false
  $deadline = [DateTime]::UtcNow.AddSeconds($StatusTimeoutSec)
  while ([DateTime]::UtcNow -lt $deadline) {
    $stRaw = (& openclaw nodes status --json 2>&1)
    if ($LASTEXITCODE -eq 0) {
      $rawSt = @()
      try { $rawSt = @(($stRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $rawSt = @() }
      $rawSt = @($rawSt | Where-Object { $_ -ne $null })
      $nodes = @()
      if ($rawSt.Count -eq 1 -and $null -ne $rawSt[0].nodes) {
        $nodes = @($rawSt[0].nodes)
      } else {
        $nodes = $rawSt
      }
      $mine = @($nodes | Where-Object { $_.displayName -ceq $NodeDisplayName })
      if ($mine.Count -eq 1 -and $mine[0].connected -eq $true -and $mine[0].version -ceq '2026.9.5') {
        $have = @($mine[0].commands | Sort-Object)
        $want = @($WANT_COMMANDS | Sort-Object)
        $extra = @($have | Where-Object { $want -notcontains $_ })
        $missing = @($want | Where-Object { $have -notcontains $_ })
        if ($extra.Count -eq 0 -and $missing.Count -eq 0) {
          $up = $true
          break
        }
        throw ("superficie distinta: extra={0} falta={1}" -f ($extra -join ','), ($missing -join ','))
      }
    }
    Start-Sleep -Seconds $PollIntervalSec
  }
  if (-not $up) { throw 'nodo sin conexion (timeout)' }
  [void]$commands.Add([PSCustomObject]@{ name = 'node-status'; exit = 0 })
  [void]$observations.Add('nodo conectado 2026.9.5 con 8 comandos')

  $leftover = @(Get-ChildItem -LiteralPath $NodeStateDir -Recurse -Filter '*.sqlite' -File -ErrorAction SilentlyContinue)
  if ($leftover.Count -gt 0) { throw 'sqlite en estado aislado' }

  try {
    $rs = Invoke-WebRequest -Uri ($HealthUrl + '/startupz') -TimeoutSec 10 -UseBasicParsing
    $h['startupz'] = [int]$rs.StatusCode
  } catch { $h['startupz'] = 0 }
  try {
    $rr = Invoke-WebRequest -Uri ($HealthUrl + '/readyz') -TimeoutSec 10 -UseBasicParsing
    $h['readyz'] = [int]$rr.StatusCode
  } catch { $h['readyz'] = 0 }
} catch {
  $failed = $true
  $failWhy = $_.Exception.Message
} finally {
  if ($null -ne $runProc) {
    Stop-Process -Id $runProc.Id -Force -ErrorAction SilentlyContinue
  }
}

$obs = $observations.ToArray()
if ($failed) {
  $why = $failWhy
  if ([string]::IsNullOrEmpty($why)) { $why = 'falla sin motivo' }
  if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
  $obs = @("FALLO: $why") + $obs
}
if ($obs.Count -eq 0) { $obs = @('nodo listo') }
if ($obs.Count -gt 20) { $obs = $obs[0..19] }
$hostName = $env:COMPUTERNAME
if ([string]::IsNullOrEmpty($hostName)) { $hostName = (& hostname) }
if ($hostName.Length -gt 128) { $hostName = $hostName.Substring(0, 128) }
$result = 'passed'
if ($failed) { $result = 'failed' }
$doc = [ordered]@{
  schema = 'runtime-separation-receipt.v1'; phase = '16'
  startedAt = $startedAt; endedAt = (Get-UtcNow)
  sourceSha = ('0' * 40); host = $hostName; openclawVersion = $ver
  commands = $commands.ToArray(); inputs = $inputs
  observations = $obs
  health = [ordered]@{ startupz = $h['startupz']; readyz = $h['readyz'] }
  result = $result
  rollback = [ordered]@{ artifact = $rbArtifact; deadlineUtc = ([DateTime]::UtcNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ')) }
}
$receiptSchema = Join-Path $PSScriptRoot '../../docs/spec/runtime-separation-receipt.v1.schema.json'
$json = (New-Object PSObject -Property $doc) | ConvertTo-Json -Depth 5 -Compress
$name = 'node-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
  [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json'
Write-ReceiptAtomic -ReceiptJson $json -Path (Join-Path $ReceiptRoot $name) -SchemaPath $receiptSchema

if ($failed) {
  Write-Output ("FALLO: {0}" -f $failWhy)
  exit 1
}
exit 0
