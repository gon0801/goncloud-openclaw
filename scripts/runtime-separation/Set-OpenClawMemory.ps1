# Set-OpenClawMemory.ps1 — migracion de memoria a Ollama + rollback (Task 5).
#
# Sin -Apply es report-only: valida la politica, imprime el plan y no escribe
# nada. Con -Apply y -Mode migrate exige version 2026.9.5, gateway detenido,
# politica completa, instalador con SHA y firma comparados ANTES de ejecutar,
# binarios instalados con hash y firma, servicio solo en loopback:11434,
# modelo nomic-embed-text con digest, vector /api/embed no vacio, snapshot
# SQLite verificado por agente, triple exacto ollama/nomic-embed-text/none
# con validate + relectura, reindex por agente, consulta semantica y cero
# eventos 3033/3077 nuevos. Rollback: con -AllowSnapshotRestore y prueba de
# no-escrituras restaura snapshots; si no, diagnostico + none/none + rebuild
# lexico. DB confinada a RuntimeRoot y snapshot a SnapshotRepo, ambos con
# hash registrado y sin reparse points. Nunca local. Salidas: 0 ok, 1 freno,
# 2 herramienta ausente.
param(
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [Parameter(Mandatory = $true)][string]$PolicyPath,
  [Parameter(Mandatory = $true)][string]$ReceiptRoot,
  [Parameter(Mandatory = $true)][string]$SnapshotRepo,
  [ValidateSet('migrate', 'rollback')][string]$Mode = 'migrate',
  [string]$MigrationPath = '',
  [string]$OllamaHost = '127.0.0.1',
  [int]$OllamaPort = 11434,
  [string]$OllamaModelsDir = '',
  [string]$OllamaInstallDir = '',
  [string]$SignatureChecker = '',
  [string]$HealthUrl = 'http://127.0.0.1:18789',
  [string]$VerifyQuery = '',
  [double]$MinVerifyScore = 0.5,
  [string]$OpenClawVersion = '',
  [switch]$AllowSnapshotRestore,
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeSeparation.psm1') -Force

function Get-UtcNow { return ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) }
function Get-FileSha([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-Full([string]$Path) {
  return [IO.Path]::GetFullPath($Path)
}
function Test-PathInside([string]$Path, [string]$Root) {
  $sep = [IO.Path]::DirectorySeparatorChar
  return ((Get-Full -Path $Path).StartsWith((Get-Full -Path $Root) + $sep,
    [StringComparison]::OrdinalIgnoreCase))
}
function Test-PathReparse([string]$Path) {
  $it = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if ($null -eq $it) { return $false }
  return ((($it.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0))
}
function Read-RollbackAgents([object]$Mig, [string]$RtFull, [string]$SnapFull) {
  $want = @('agent', 'snapshot', 'snapshotHash', 'dbHash', 'dbPath',
    'priorProvider', 'priorModel')
  $sep = [IO.Path]::DirectorySeparatorChar
  $out = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($a in @($Mig.agents)) {
    $got = @($a.PSObject.Properties.Name)
    if ($got.Count -ne $want.Count) { throw 'migration.json con agente ajeno' }
    foreach ($k in $want) {
      if ($got -notcontains $k) { throw 'migration.json con agente ajeno' }
    }
    $id = [string]$a.agent
    if ([string]::IsNullOrEmpty($id)) { throw 'agente sin id' }
    if ($a.dbHash -cnotmatch '^[0-9a-f]{64}$') { throw 'migration.json sin dbHash' }
    if ($a.snapshotHash -cnotmatch '^[0-9a-f]{64}$') { throw 'migration.json sin snapshotHash' }
    if ([string]::IsNullOrEmpty($a.dbPath) -or [string]::IsNullOrEmpty($a.snapshot)) {
      throw 'migration.json sin rutas'
    }
    if ($a.priorProvider -ceq 'local') { throw 'prior local prohibido' }
    $db = Get-Full -Path $a.dbPath
    $snap = Get-Full -Path $a.snapshot
    if (-not $db.StartsWith($RtFull + $sep, [StringComparison]::OrdinalIgnoreCase)) {
      throw ("db fuera de runtime: {0}" -f $id)
    }
    if (-not $snap.StartsWith($SnapFull + $sep, [StringComparison]::OrdinalIgnoreCase)) {
      throw ("snapshot fuera de repo: {0}" -f $id)
    }
    if ($seen.ContainsKey($id)) { throw ("agente duplicado: {0}" -f $id) }
    $seen[$id] = $true
    [void]$out.Add([PSCustomObject]@{
        Agent = $id; Db = $db; Snap = $snap
        DbHash = [string]$a.dbHash; SnapHash = [string]$a.snapshotHash
      })
  }
  return $out
}
function Get-ResolvedVersion([string]$Pinned) {
  if (-not [string]::IsNullOrEmpty($Pinned)) { return $Pinned }
  $v = (& openclaw --version 2>&1 | Out-String)
  $m = [regex]::Match($v, '(\d{4}\.\d+\.\d+)')
  if (-not $m.Success) { throw 'version openclaw irresoluble' }
  return $m.Groups[1].Value
}
function Get-HttpErrorStatus($ErrorRecord) {
  # Codigo HTTP de un error de Invoke-WebRequest, en 5.1 y 7. 0 = sin
  # respuesta HTTP (sin listener, DNS, timeout...).
  try {
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
      $sc = $null
      try { $sc = $ex.StatusCode } catch { $sc = $null }
      if ($null -ne $sc) {
        $n = 0
        try { $n = [int]$sc } catch { $n = 0 }
        if ($n -ge 100 -and $n -le 599) { return $n }
      }
      $resp = $null
      try { $resp = $ex.Response } catch { $resp = $null }
      if ($null -ne $resp) {
        $rsc = $null
        try { $rsc = $resp.StatusCode } catch { $rsc = $null }
        if ($null -ne $rsc) {
          $n = 0
          try { $n = [int]$rsc } catch { $n = 0 }
          if ($n -ge 100 -and $n -le 599) { return $n }
        }
      }
      $ex = $ex.InnerException
    }
  } catch { }
  try {
    $t = [string]$ErrorRecord.Exception.Message
    # Solo 4xx/5xx: los octetos de IP (127...) son 1xx y no cuentan.
    $m = [regex]::Match($t, '\b([45]\d{2})\b')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    if ($t -match 'Unauthorized|Forbidden|Not Found|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout') { return 500 }
  } catch { }
  return 0
}
function Test-GatewayUp([string]$Url) {
  try {
    [void](Invoke-WebRequest -Uri ($Url + '/startupz') -TimeoutSec 5 -UseBasicParsing)
    return $true
  } catch {
    # Cualquier respuesta HTTP (401/500/503/...) = listener vivo.
    if ((Get-HttpErrorStatus -ErrorRecord $_) -ne 0) { return $true }
    $msg = ''
    try { $msg = [string]$_.Exception.Message } catch { $msg = '' }
    # Solo "conexion rechazada / sin listener" acredita apagado. No se
    # anade senal de proceso o tarea: el nombre de proceso no identifica
    # ESTE endpoint (un OpenClaw ajeno puede vivir en la maquina) y la
    # tarea existe tambien detenida con estado en texto localizado.
    if ($msg -match 'Connection refused|No connection could be made|Unable to connect|No se puede establecer|rehus|refused') {
      return $false
    }
    # Indeterminado (timeout, DNS, TLS...): fallar cerrado.
    return $true
  }
}
# La politica vive en config/ollama-runtime.v1.json (ruta via -PolicyPath).
function Read-Policy([string]$Path) {
  $p = $null
  try { $p = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { $p = $null }
  if ($null -eq $p) { throw 'politica ilegible' }
  if ($p.schema -cne 'ollama-runtime.v1') { throw 'politica con schema ajeno' }
  if ($p.ollamaVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'politica sin ollamaVersion' }
  $u = $p.installer.url
  if ($u -notmatch '^https://github\.com/ollama/ollama/releases/download/' -and $u -notmatch '^https://ollama\.com/') {
    throw 'politica sin URL oficial'
  }
  if ($p.installer.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'politica sin sha256 de instalador' }
  if (-not ($p.installer.sizeBytes -gt 0)) { throw 'politica sin sizeBytes' }
  if (@($p.installer.args).Count -eq 0) { throw 'politica sin args de instalador' }
  foreach ($k in @('subjectCN', 'issuerCN', 'rootCN')) {
    if ([string]::IsNullOrEmpty($p.authenticode.$k)) { throw ("politica sin authenticode.{0}" -f $k) }
  }
  if ($p.authenticode.status -cne 'Valid') { throw 'politica sin status Valid' }
  if (@($p.installedBinaries).Count -eq 0) { throw 'politica sin installedBinaries' }
  foreach ($b in @($p.installedBinaries)) {
    if ($b.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'politica sin sha256 de binario' }
    if ([string]::IsNullOrEmpty($b.subjectCN)) { throw 'politica sin subjectCN de binario' }
  }
  if ($p.service.host -cne '127.0.0.1' -or $p.service.port -ne 11434) { throw 'politica sin loopback:11434' }
  if ($p.model.name -cne 'nomic-embed-text') { throw 'politica sin modelo' }
  if ($p.model.manifestDigest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'politica sin manifestDigest' }
  $ms = $p.memorySearch
  if ($ms.provider -cne 'ollama' -or $ms.model -cne 'nomic-embed-text' -or $ms.fallback -cne 'none') {
    throw 'politica sin triple exacto'
  }
  if ([string]::IsNullOrEmpty($p.reviewedBy)) { throw 'politica sin revision' }
  return $p
}
function Test-AuthenticodePolicy([string]$Path, [string]$WantSubject, [string]$WantIssuer, [string]$Checker) {
  if (-not [string]::IsNullOrEmpty($Checker)) {
    $out = (& $Checker $Path 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'signature checker fallo' }
    $parts = ($out.Trim() -split '\|')
    if ($parts.Count -lt 3) { throw 'signature checker sin forma' }
    if ($parts[0] -cne 'Valid') { throw ("firma no valida: {0}" -f $parts[0]) }
    if ($parts[1] -notmatch [regex]::Escape($WantSubject)) { throw 'subject inesperado' }
    if ($parts[2] -notmatch [regex]::Escape($WantIssuer)) { throw 'issuer inesperado' }
    return
  }
  if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
    throw 'authenticode unverificable en esta plataforma'
  }
  $sig = Get-AuthenticodeSignature -LiteralPath $Path
  if ($sig.Status -cne 'Valid') { throw ("firma no valida: {0}" -f $sig.Status) }
  if ($sig.SignerCertificate.Subject -notmatch [regex]::Escape($WantSubject)) { throw 'subject inesperado' }
  if ($sig.SignerCertificate.Issuer -notmatch [regex]::Escape($WantIssuer)) { throw 'issuer inesperado' }
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

  $pol = Read-Policy -Path $PolicyPath
  [void]$commands.Add([PSCustomObject]@{ name = 'policy'; exit = 0 })
  $inputs['policy'] = [ordered]@{ algo = 'sha256'; sha256 = (Get-FileSha -Path $PolicyPath) }
  if ($OllamaHost -cne $pol.service.host -or $OllamaPort -ne $pol.service.port) {
    throw 'endpoint fuera de politica'
  }

  if ($Mode -ceq 'rollback' -and [string]::IsNullOrEmpty($MigrationPath)) {
    throw 'rollback exige -MigrationPath'
  }

  if (-not $Apply) {
    if ($Mode -ceq 'migrate') {
      Write-Output 'plan migrate: gateway detenido + politica + SHA/firma antes de ejecutar'
      Write-Output 'plan migrate: instalar, binarios, loopback:11434, ollama pull'
      Write-Output 'plan migrate: digest, /api/embed, snapshots por agente'
      Write-Output 'plan migrate: triple exacto + validate + relectura + index + semantica'
      Write-Output 'plan migrate: bookmark de eventos + recibo'
    } else {
      $mig0 = $null
      try { $mig0 = Get-Content -Raw -LiteralPath $MigrationPath | ConvertFrom-Json } catch { $mig0 = $null }
      if ($null -eq $mig0 -or $mig0.schema -cne 'memory-migration.v1') { throw 'migration.json invalido' }
      $rb0 = Read-RollbackAgents -Mig $mig0 -RtFull (Get-Full -Path $RuntimeRoot) `
        -SnapFull (Get-Full -Path $SnapshotRepo)
      $allMatch = $true
      foreach ($a in $rb0) {
        if (-not (Test-Path -LiteralPath $a.Db -PathType Leaf)) { $allMatch = $false; break }
        if (Test-PathReparse -Path $a.Db) { throw ("db reparse: {0}" -f $a.Agent) }
        if ((Get-FileSha -Path $a.Db) -cne $a.DbHash) { $allMatch = $false; break }
        if (-not (Test-Path -LiteralPath $a.Snap -PathType Leaf)) { $allMatch = $false; break }
        if (Test-PathReparse -Path $a.Snap) { throw ("snapshot reparse: {0}" -f $a.Agent) }
        if ((Get-FileSha -Path $a.Snap) -cne $a.SnapHash) { $allMatch = $false; break }
      }
      if ($AllowSnapshotRestore -and $allMatch) {
        Write-Output 'plan rollback: via snapshot-restore (hashes coinciden + switch)'
      } else {
        Write-Output 'plan rollback: via diagnostic (sin restore de bases)'
      }
    }
    foreach ($o in $observations) { Write-Output ("plan: observacion: {0}" -f $o) }
    exit 0
  }

  if (-not (Test-Path -LiteralPath $ReceiptRoot)) {
    [void](New-Item -ItemType Directory -Path $ReceiptRoot -Force)
  }

  if ($Mode -ceq 'migrate') {
    foreach ($tool in @('openclaw', 'ollama', 'curl', 'netstat', 'wevtutil')) {
      if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Output ("FALLO: herramienta ausente: {0}" -f $tool)
        exit 2
      }
    }
    if (-not [string]::IsNullOrEmpty($SignatureChecker) -and !(Test-Path -LiteralPath $SignatureChecker)) {
      Write-Output 'FALLO: signature checker ausente'
      exit 2
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'tools'; exit = 0 })
    if ([string]::IsNullOrEmpty($VerifyQuery)) { throw 'migrate exige -VerifyQuery' }
    if (Test-GatewayUp -Url $HealthUrl) { throw 'gateway en marcha: se exige detenido' }
    [void]$commands.Add([PSCustomObject]@{ name = 'gateway-down'; exit = 0 })

    $modelsDir = $OllamaModelsDir
    if ([string]::IsNullOrEmpty($modelsDir)) {
      if (-not [string]::IsNullOrEmpty($env:OLLAMA_MODELS)) {
        $modelsDir = $env:OLLAMA_MODELS
      } elseif ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $modelsDir = Join-Path $env:USERPROFILE '.ollama/models'
      } else {
        $modelsDir = Join-Path $env:HOME '.ollama/models'
      }
    }
    $installDir = $OllamaInstallDir
    if ([string]::IsNullOrEmpty($installDir)) {
      if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        $installDir = Join-Path $env:LOCALAPPDATA 'Programs/Ollama'
      } else {
        throw 'OllamaInstallDir requerido'
      }
    }
    if (-not (Test-Path -LiteralPath $SnapshotRepo)) {
      [void](New-Item -ItemType Directory -Path $SnapshotRepo -Force)
    }
    $migPath = Join-Path $SnapshotRepo 'migration.json'
    if (Test-Path -LiteralPath $migPath) { throw 'ya existe migration.json' }

    $bmRaw = (& wevtutil qe Application /c:1 /rd:true /f:text 2>&1 | Out-String)
    $bm = ''
    $bmm = [regex]::Match($bmRaw, 'EventRecordID:\s*(\d+)')
    if ($bmm.Success) { $bm = $bmm.Groups[1].Value }
    [void]$commands.Add([PSCustomObject]@{ name = 'event-bookmark'; exit = 0 })
    [void]$observations.Add("bookmark eventos: $bm")

    $tmpInst = Join-Path ([IO.Path]::GetTempPath()) ('ollama-installer-' + [Guid]::NewGuid().ToString('N') + '.exe')
    try {
      & curl -sSL --fail -o $tmpInst $pol.installer.url 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'descarga del instalador fallo' }
      [void]$commands.Add([PSCustomObject]@{ name = 'installer-download'; exit = 0 })
      if ((Get-Item -LiteralPath $tmpInst).Length -ne $pol.installer.sizeBytes) {
        throw 'instalador con tamano distinto'
      }
      $instSha = Get-FileSha -Path $tmpInst
      if ($instSha -cne $pol.installer.sha256) { throw 'instalador con SHA distinto' }
      [void]$commands.Add([PSCustomObject]@{ name = 'installer-sha'; exit = 0 })
      $inputs['installer'] = [ordered]@{ algo = 'sha256'; sha256 = $instSha }
      Test-AuthenticodePolicy -Path $tmpInst -WantSubject $pol.authenticode.subjectCN `
        -WantIssuer $pol.authenticode.issuerCN -Checker $SignatureChecker
      [void]$commands.Add([PSCustomObject]@{ name = 'installer-signature'; exit = 0 })
      [void]$observations.Add('instalador verificado antes de ejecutar')

      $instArgs = @($pol.installer.args)
      & $tmpInst @instArgs 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'instalador fallo' }
      [void]$commands.Add([PSCustomObject]@{ name = 'installer-exec'; exit = 0 })
    } finally {
      if (Test-Path -LiteralPath $tmpInst) {
        Remove-Item -LiteralPath $tmpInst -Force -ErrorAction SilentlyContinue
      }
    }

    foreach ($b in @($pol.installedBinaries)) {
      $bp = Join-Path $installDir $b.name
      if (-not (Test-Path -LiteralPath $bp -PathType Leaf)) { throw ("binario ausente: {0}" -f $b.name) }
      if ((Get-FileSha -Path $bp) -cne $b.sha256) { throw ("binario con SHA distinto: {0}" -f $b.name) }
      Test-AuthenticodePolicy -Path $bp -WantSubject $b.subjectCN `
        -WantIssuer $pol.authenticode.issuerCN -Checker $SignatureChecker
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'installed-binaries'; exit = 0 })

    $nsRaw = (& netstat -ano 2>&1 | Out-String)
    $wantListen = '{0}:{1}' -f $pol.service.host, $pol.service.port
    if ($nsRaw -notmatch [regex]::Escape($wantListen)) { throw 'ollama no escucha en loopback' }
    if ($nsRaw -match ('0\.0\.0\.0:{0}' -f $pol.service.port)) { throw 'ollama expuesto fuera de loopback' }
    [void]$commands.Add([PSCustomObject]@{ name = 'loopback'; exit = 0 })

    & ollama pull $pol.model.name 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'ollama pull fallo' }
    $listRaw = (& ollama list 2>&1 | Out-String)
    if ($listRaw -notmatch [regex]::Escape($pol.model.name)) { throw 'modelo ausente en ollama list' }
    [void]$commands.Add([PSCustomObject]@{ name = 'model-pull'; exit = 0 })
    $manRel = 'manifests/registry.ollama.ai/library/' + $pol.model.name + '/latest'
    $manPath = Join-Path $modelsDir ($manRel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $manPath -PathType Leaf)) { throw 'manifiesto del modelo ausente' }
    $wantDigest = $pol.model.manifestDigest -replace '^sha256:', ''
    if ((Get-FileSha -Path $manPath) -cne $wantDigest) { throw 'digest del modelo distinto' }
    [void]$commands.Add([PSCustomObject]@{ name = 'model-digest'; exit = 0 })
    $inputs['model'] = [ordered]@{ algo = 'sha256'; sha256 = $wantDigest }

    $embedBody = (@{ model = $pol.model.name; input = ("migration probe $stamp") } | ConvertTo-Json -Compress)
    $embed = $null
    try {
      $embed = Invoke-RestMethod -Method Post -Uri ("http://{0}:{1}/api/embed" -f $OllamaHost, $OllamaPort) `
        -Body $embedBody -ContentType 'application/json' -TimeoutSec 120
    } catch {
      throw 'api embed no respondio'
    }
    $vecs = @($embed.embeddings)
    if ($vecs.Count -eq 0 -or @($vecs[0]).Count -eq 0) { throw 'vector embed vacio' }
    [void]$commands.Add([PSCustomObject]@{ name = 'embed-probe'; exit = 0 })
    [void]$observations.Add(("embed dim: {0}" -f @($vecs[0]).Count))

    $stRaw = (& openclaw memory status --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'memory status fallo' }
    $agents = @()
    # foreach aplanar (CI17): @(...|ConvertFrom-Json) envuelve en 5.1.
    $agentsRaw = $null
    try { $agentsRaw = (($stRaw | Out-String) | ConvertFrom-Json) } catch { $agentsRaw = $null }
    $agents = @()
    foreach ($a in $agentsRaw) { $agents += $a }
    if ($agents.Count -eq 0) { throw 'sin agentes' }
    $priorRaw = (& openclaw config get memory.search --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'config get fallo' }
    $prior = $null
    try { $prior = (($priorRaw | Out-String) | ConvertFrom-Json) } catch { $prior = $null }
    if ($null -eq $prior) { throw 'prior ilegible' }

    $snaps = New-Object System.Collections.Generic.List[object]
    $seenMig = @{}
    foreach ($g in $agents) {
      $id = $g.agentId
      if ([string]::IsNullOrEmpty($id)) { throw 'agente sin id' }
      if ($seenMig.ContainsKey($id)) { throw ("agente duplicado: {0}" -f $id) }
      $seenMig[$id] = $true
      $dbp = $g.dbPath
      if ([string]::IsNullOrEmpty($dbp) -or !(Test-Path -LiteralPath $dbp -PathType Leaf)) {
        throw ("db ausente: {0}" -f $id)
      }
      if (-not (Test-PathInside -Path $dbp -Root $RuntimeRoot)) {
        throw ("db fuera de runtime: {0}" -f $id)
      }
      if (Test-PathReparse -Path $dbp) { throw ("db reparse: {0}" -f $id) }
      $dbp = Get-Full -Path $dbp
      $crRaw = (& openclaw backup sqlite create --agent $id --repository $SnapshotRepo --json 2>&1)
      if ($LASTEXITCODE -ne 0) { throw ("snapshot fallo: {0}" -f $id) }
      $snapPath = ''
      try { $snapPath = ((($crRaw | Out-String) | ConvertFrom-Json).snapshot) } catch { $snapPath = '' }
      if ([string]::IsNullOrEmpty($snapPath)) { throw ("snapshot sin ruta: {0}" -f $id) }
      if (-not (Test-PathInside -Path $snapPath -Root $SnapshotRepo)) {
        throw ("snapshot fuera de repo: {0}" -f $id)
      }
      if (Test-PathReparse -Path $snapPath) { throw ("snapshot reparse: {0}" -f $id) }
      $snapPath = Get-Full -Path $snapPath
      $scratch = Join-Path ([IO.Path]::GetTempPath()) ('snap-verify-' + [Guid]::NewGuid().ToString('N'))
      [void](New-Item -ItemType Directory -Path $scratch -Force)
      try {
        $vfRaw = (& openclaw backup sqlite verify $snapPath --scratch $scratch --json 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ("snapshot no verifico: {0}" -f $id) }
      } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
      }
      [void]$snaps.Add([PSCustomObject]@{
          agent = $id; snapshot = $snapPath; dbHash = (Get-FileSha -Path $dbp); dbPath = $dbp
          snapshotHash = (Get-FileSha -Path $snapPath)
          priorProvider = $g.provider; priorModel = $g.model
        })
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'snapshots'; exit = 0 })
    [void]$observations.Add(("snapshots: {0} agentes" -f $snaps.Count))

    $mig = [ordered]@{
      schema = 'memory-migration.v1'; createdUtc = (Get-UtcNow)
      agents = @($snaps.ToArray() | ForEach-Object {
          [ordered]@{ agent = $_.agent; snapshot = $_.snapshot; snapshotHash = $_.snapshotHash
            dbHash = $_.dbHash; dbPath = $_.dbPath; priorProvider = $_.priorProvider
            priorModel = $_.priorModel }
        })
      globalPrior = [ordered]@{ provider = $prior.provider; model = $prior.model; fallback = $prior.fallback }
      policyDigest = ('sha256:' + (Get-FileSha -Path $PolicyPath))
    }
    $migJson = (New-Object PSObject -Property $mig) | ConvertTo-Json -Depth 5 -Compress
    $migTmp = $migPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($migTmp, $migJson, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $migTmp -Destination $migPath -Force

    $ms = $pol.memorySearch
    & openclaw config set memory.search.provider $ms.provider 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'config set provider fallo' }
    & openclaw config set memory.search.model $ms.model 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'config set model fallo' }
    & openclaw config set memory.search.fallback $ms.fallback 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'config set fallback fallo' }
    [void]$commands.Add([PSCustomObject]@{ name = 'config-set'; exit = 0 })
    $valRaw = (& openclaw config validate --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'config validate fallo' }
    $valOk = $false
    try { $valOk = (((($valRaw | Out-String) | ConvertFrom-Json).ok) -eq $true) } catch { $valOk = $false }
    if (-not $valOk) { throw 'config validate no-ok' }
    $rbRaw = (& openclaw config get memory.search --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'config readback fallo' }
    $rb = $null
    try { $rb = (($rbRaw | Out-String) | ConvertFrom-Json) } catch { $rb = $null }
    if ($null -eq $rb -or $rb.provider -cne $ms.provider -or $rb.model -cne $ms.model -or $rb.fallback -cne $ms.fallback) {
      throw 'readback distinto del triple'
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'config-readback'; exit = 0 })

    foreach ($g in $agents) {
      & openclaw memory index --agent $g.agentId --force 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw ("index fallo: {0}" -f $g.agentId) }
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'reindex'; exit = 0 })

    foreach ($g in $agents) {
      $sRaw = (& openclaw memory search --agent $g.agentId --json --query $VerifyQuery 2>&1)
      if ($LASTEXITCODE -ne 0) { throw ("search fallo: {0}" -f $g.agentId) }
      $res = @()
      try { $res = @((($sRaw | Out-String) | ConvertFrom-Json).results) } catch { $res = @() }
      $semantic = $false
      foreach ($r in $res) {
        if ($r.score -ge $MinVerifyScore) {
          $snip = [string]$r.snippet
          if ($snip.IndexOf($VerifyQuery, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            $semantic = $true
            break
          }
        }
      }
      if (-not $semantic) { throw ("sin resultado semantico: {0}" -f $g.agentId) }
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'semantic-verify'; exit = 0 })

    $evRaw = (& wevtutil qe Application '/q:*[System[(EventID=3033 or EventID=3077)]]' /f:text /c:50 2>&1 | Out-String)
    if ($evRaw -match '3033|3077') { throw 'eventos 3033/3077 de llama-server tras el cambio' }
    [void]$commands.Add([PSCustomObject]@{ name = 'event-check'; exit = 0 })

    $rbArtifact = $SnapshotRepo
    foreach ($g in $agents) {
      $s = @($snaps | Where-Object { $_.agent -ceq $g.agentId })[0]
      [void]$observations.Add(("agente {0}: snapshot {1} prior {2}/{3}" -f $g.agentId, (Split-Path -Leaf $s.snapshot), $s.priorProvider, $s.priorModel))
    }
  } else {
    if ($null -eq (Get-Command 'openclaw' -ErrorAction SilentlyContinue)) {
      Write-Output 'FALLO: herramienta ausente: openclaw'
      exit 2
    }
    $mig = $null
    try { $mig = Get-Content -Raw -LiteralPath $MigrationPath | ConvertFrom-Json } catch { $mig = $null }
    if ($null -eq $mig -or $mig.schema -cne 'memory-migration.v1') { throw 'migration.json invalido' }
    if (@($mig.agents).Count -eq 0) { throw 'migration.json sin agentes' }
    $gp = $mig.globalPrior
    if ($null -eq $gp -or [string]::IsNullOrEmpty($gp.provider)) { throw 'migration.json sin globalPrior' }
    if ($gp.provider -ceq 'local') { throw 'prior local prohibido' }
    $rb = Read-RollbackAgents -Mig $mig -RtFull (Get-Full -Path $RuntimeRoot) `
      -SnapFull (Get-Full -Path $SnapshotRepo)
    [void]$commands.Add([PSCustomObject]@{ name = 'migration-load'; exit = 0 })
    $migSha = Get-FileSha -Path $MigrationPath
    [void]$observations.Add(("migration sha256: {0}" -f $migSha))

    if (Test-GatewayUp -Url $HealthUrl) {
      & openclaw daemon stop 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'gateway no se detiene' }
      [void]$commands.Add([PSCustomObject]@{ name = 'daemon-stop'; exit = 0 })
      [void]$observations.Add('gateway detenido para rollback')
    }

    $canSnap = [bool]$AllowSnapshotRestore
    $whyNot = ''
    if ($canSnap) {
      foreach ($a in $rb) {
        if (-not (Test-Path -LiteralPath $a.Db -PathType Leaf)) {
          $canSnap = $false; $whyNot = ("db ausente: {0}" -f $a.Agent); break
        }
        if (Test-PathReparse -Path $a.Db) { throw ("db reparse: {0}" -f $a.Agent) }
        if ((Get-FileSha -Path $a.Db) -cne $a.DbHash) {
          $canSnap = $false; $whyNot = ("escrituras tras snapshot: {0}" -f $a.Agent); break
        }
        if (-not (Test-Path -LiteralPath $a.Snap -PathType Leaf)) {
          $canSnap = $false; $whyNot = ("snapshot ausente: {0}" -f $a.Agent); break
        }
        if (Test-PathReparse -Path $a.Snap) { throw ("snapshot reparse: {0}" -f $a.Agent) }
        if ((Get-FileSha -Path $a.Snap) -cne $a.SnapHash) {
          $canSnap = $false; $whyNot = ("snapshot distinto: {0}" -f $a.Agent); break
        }
      }
    } else {
      $whyNot = 'sin -AllowSnapshotRestore'
    }

    if ($canSnap) {
      foreach ($a in $rb) {
        $scratch = Join-Path ([IO.Path]::GetTempPath()) ('snap-verify-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $scratch -Force)
        try {
          $vfRaw = (& openclaw backup sqlite verify $a.Snap --scratch $scratch --json 2>&1)
          if ($LASTEXITCODE -ne 0) { throw ("snapshot no verifico: {0}" -f $a.Agent) }
        } finally {
          Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
        $freshTarget = $a.Db + '.restored'
        if (Test-Path -LiteralPath $freshTarget) {
          Remove-Item -LiteralPath $freshTarget -Force
        }
        $rsRaw = (& openclaw backup sqlite restore $a.Snap --target $freshTarget --json 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ("snapshot restore fallo: {0}" -f $a.Agent) }
        if (-not (Test-Path -LiteralPath $freshTarget -PathType Leaf)) {
          throw ("restore sin destino: {0}" -f $a.Agent)
        }
        if (Test-PathReparse -Path $freshTarget) { throw ("restore reparse: {0}" -f $a.Agent) }
        Move-Item -LiteralPath $freshTarget -Destination $a.Db -Force
        foreach ($side in @('-wal', '-shm', '-journal')) {
          $sp = $a.Db + $side
          if (Test-Path -LiteralPath $sp) { Remove-Item -LiteralPath $sp -Force }
        }
      }
      [void]$commands.Add([PSCustomObject]@{ name = 'snapshot-restore'; exit = 0 })
      [void]$observations.Add('rollback via snapshot-restore')
      & openclaw config set memory.search.provider $gp.provider 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'config set provider fallo' }
      & openclaw config set memory.search.model $gp.model 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'config set model fallo' }
      & openclaw config set memory.search.fallback $gp.fallback 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'config set fallback fallo' }
      [void]$commands.Add([PSCustomObject]@{ name = 'config-revert'; exit = 0 })
      $rbArtifact = $SnapshotRepo
    } else {
      [void]$observations.Add("snapshot-restore rechazado: $whyNot; via diagnostic")
      $diagDir = Join-Path $SnapshotRepo ("diag-" + $stamp)
      [void](New-Item -ItemType Directory -Path $diagDir -Force)
      $dgRaw = (& openclaw backup create --verify --output $diagDir --json 2>&1)
      if ($LASTEXITCODE -ne 0) { throw 'backup diagnostico fallo' }
      $dgPath = ''
      try { $dgPath = ((($dgRaw | Out-String) | ConvertFrom-Json).archivePath) } catch { $dgPath = '' }
      if ([string]::IsNullOrEmpty($dgPath)) { throw 'diagnostico sin archivePath' }
      [void]$commands.Add([PSCustomObject]@{ name = 'diagnostic-backup'; exit = 0 })
      [void]$observations.Add("diagnostico: $dgPath")
      $rbArtifact = $diagDir
      & openclaw config set memory.search.provider none 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'config set provider fallo' }
      & openclaw config set memory.search.fallback none 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'config set fallback fallo' }
      [void]$commands.Add([PSCustomObject]@{ name = 'config-none'; exit = 0 })
    }

    $valRaw = (& openclaw config validate --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'config validate fallo' }
    $valOk = $false
    try { $valOk = (((($valRaw | Out-String) | ConvertFrom-Json).ok) -eq $true) } catch { $valOk = $false }
    if (-not $valOk) { throw 'config validate no-ok' }
    $rbRaw = (& openclaw config get memory.search --json 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'config readback fallo' }
    $rb = $null
    try { $rb = (($rbRaw | Out-String) | ConvertFrom-Json) } catch { $rb = $null }
    if ($canSnap) {
      if ($null -eq $rb -or $rb.provider -cne $gp.provider -or $rb.model -cne $gp.model -or $rb.fallback -cne $gp.fallback) {
        throw 'readback distinto del prior'
      }
    } else {
      if ($null -eq $rb -or $rb.provider -cne 'none' -or $rb.fallback -cne 'none') {
        throw 'readback distinto de none/none'
      }
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'config-readback'; exit = 0 })

    foreach ($a in @($mig.agents)) {
      & openclaw memory index --agent $a.agent --force 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { throw ("index fallo: {0}" -f $a.agent) }
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'reindex'; exit = 0 })

    if (-not $canSnap) {
      foreach ($a in @($mig.agents)) {
        $sRaw = (& openclaw memory search --agent $a.agent --json --query 'rollback-lexical-probe' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw ("search fallo: {0}" -f $a.agent) }
        $res = @()
        try { $res = @((($sRaw | Out-String) | ConvertFrom-Json).results) } catch { $res = @() }
        if ($res.Count -eq 0) { throw ("sin resultados lexicos: {0}" -f $a.agent) }
      }
      [void]$commands.Add([PSCustomObject]@{ name = 'lexical-verify'; exit = 0 })
    }

    & openclaw daemon start 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'gateway no reinicia' }
    [void]$commands.Add([PSCustomObject]@{ name = 'daemon-start'; exit = 0 })
    try {
      $rs = Invoke-WebRequest -Uri ($HealthUrl + '/startupz') -TimeoutSec 10 -UseBasicParsing
      $h['startupz'] = [int]$rs.StatusCode
    } catch { $h['startupz'] = 0 }
    try {
      $rr = Invoke-WebRequest -Uri ($HealthUrl + '/readyz') -TimeoutSec 10 -UseBasicParsing
      $h['readyz'] = [int]$rr.StatusCode
    } catch { $h['readyz'] = 0 }
    if ($h['startupz'] -eq 200 -and $h['readyz'] -eq 200) {
      [void]$observations.Add('health-verified')
    } else {
      [void]$observations.Add('gateway sin verificar tras reinicio')
    }
  }
} catch {
  $failed = $true
  $failWhy = $_.Exception.Message
}

$obs = $observations.ToArray()
if ($failed) {
  $why = $failWhy
  if ([string]::IsNullOrEmpty($why)) { $why = 'falla sin motivo' }
  if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
  $obs = @("FALLO: $why") + $obs
}
if ($obs.Count -eq 0) { $obs = @('memoria migrada') }
if ($obs.Count -gt 20) { $obs = $obs[0..19] }
$hostName = $env:COMPUTERNAME
if ([string]::IsNullOrEmpty($hostName)) { $hostName = (& hostname) }
if ($hostName.Length -gt 128) { $hostName = $hostName.Substring(0, 128) }
$result = 'passed'
if ($failed) { $result = 'failed' }
$srcSha = '0' * 40
$doc = [ordered]@{
  schema = 'runtime-separation-receipt.v1'; phase = '16'
  startedAt = $startedAt; endedAt = (Get-UtcNow)
  sourceSha = $srcSha; host = $hostName; openclawVersion = $ver
  commands = $commands.ToArray(); inputs = $inputs
  observations = $obs
  health = [ordered]@{ startupz = $h['startupz']; readyz = $h['readyz'] }
  result = $result
  rollback = [ordered]@{ artifact = $rbArtifact; deadlineUtc = ([DateTime]::UtcNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ')) }
}
$receiptSchema = Join-Path $PSScriptRoot '../../docs/spec/runtime-separation-receipt.v1.schema.json'
$json = (New-Object PSObject -Property $doc) | ConvertTo-Json -Depth 5 -Compress
$name = $Mode + '-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
  [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json'
Write-ReceiptAtomic -ReceiptJson $json -Path (Join-Path $ReceiptRoot $name) -SchemaPath $receiptSchema

if ($failed) {
  Write-Output ("FALLO: {0}" -f $failWhy)
  exit 1
}
exit 0
