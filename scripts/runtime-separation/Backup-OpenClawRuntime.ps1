# Backup-OpenClawRuntime.ps1 — respaldo verificado del runtime (Fase 16, Task 5).
#
# Sin -Apply es report-only: imprime el plan y no escribe nada. Con -Apply
# exige version 2026.9.5, gateway detenido, espacio libre y staging fresco
# fuera de repo/runtime con ACL restringida (SYSTEM + Administradores por
# SID); crea el archive con `backup create --verify`, lo verifica, lo
# restaura a staging y exige cobertura (estado, bases de agentes,
# credenciales, workspaces); bundle git valido, XML de las cinco tareas,
# launchers con hash e inventario. La evidencia guarda solo ruta, tamano,
# hash, timestamp y pass/fail. Salidas: 0 ok, 1 freno, 2 herramienta ausente.
param(
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [Parameter(Mandatory = $true)][string]$RepoRoot,
  [Parameter(Mandatory = $true)][string]$BackupDir,
  [Parameter(Mandatory = $true)][string]$StagingRoot,
  [Parameter(Mandatory = $true)][string]$EvidencePath,
  [Parameter(Mandatory = $true)][string]$ReceiptRoot,
  [string[]]$LauncherPaths = @(),
  [string[]]$TaskNames = @('OpenClaw Gateway', 'OpenClaw Gateway Watchdog', 'OpenClaw Node', 'OpenClaw CUA Node', 'GoncloudRepoSync'),
  [string[]]$ExpectedWorkspaces = @('workspace', 'workspace-ingenieria', 'workspace-operaciones'),
  [string[]]$InventoryPaths = @(),
  [long]$MinFreeBytes = 1073741824,
  [string]$HealthUrl = 'http://127.0.0.1:18789',
  [string]$OpenClawVersion = '',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeSeparation.psm1') -Force

# CLI (-File) no arma arrays: aceptar elementos unidos con ';' ademas del
# array real cuando se llama desde PowerShell.
$LauncherPaths = @($LauncherPaths | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })
$TaskNames = @($TaskNames | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })
$ExpectedWorkspaces = @($ExpectedWorkspaces | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })
$InventoryPaths = @($InventoryPaths | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })

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
function Test-GatewayUp([string]$Url) {
  try {
    [void](Invoke-WebRequest -Uri ($Url + '/startupz') -TimeoutSec 5 -UseBasicParsing)
    return $true
  } catch {
    return $false
  }
}
function Get-DriveFree([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  $best = $null
  foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
    $root = [IO.Path]::GetFullPath($d.Root)
    if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
      if ($null -eq $best -or $root.Length -gt $best.Root.Length) {
        $best = [PSCustomObject]@{ Root = $root; Free = $d.Free }
      }
    }
  }
  if ($null -eq $best) { throw "sin unidad para $Path" }
  return [long]$best.Free
}

$startedAt = Get-UtcNow
$commands = New-Object System.Collections.Generic.List[object]
$observations = New-Object System.Collections.Generic.List[string]
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$archivePath = ''
$archiveSha = ''
$archiveSize = [long]0
$failed = $false
$failWhy = ''

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
    if ($Apply) {
      [void]$commands.Add([PSCustomObject]@{ name = 'version'; exit = 1 })
      throw 'se requiere openclaw 2026.9.5 para -Apply'
    }
    [void]$observations.Add("version $ver (se requiere 2026.9.5 para -Apply)")
  } else {
    [void]$commands.Add([PSCustomObject]@{ name = 'version'; exit = 0 })
  }

  if (-not $Apply) {
    Write-Output 'plan backup: gateway detenido + espacio libre'
    Write-Output 'plan backup: openclaw backup create --verify --output <BackupDir>'
    Write-Output 'plan backup: openclaw backup verify <archive>'
    Write-Output 'plan backup: staging fresco + icacls + openclaw backup restore'
    Write-Output 'plan backup: manifiesto con estado, agentes, credenciales, workspaces'
    Write-Output 'plan backup: git bundle create --all + bundle verify'
    foreach ($t in $TaskNames) { Write-Output ("plan backup: schtasks /query /tn {0} /xml" -f $t) }
    Write-Output 'plan backup: launchers + inventario + evidencia + recibo'
    foreach ($o in $observations) { Write-Output ("plan backup: observacion: {0}" -f $o) }
    Write-Output 'plan backup: 2026.9.5 requerido para -Apply'
    exit 0
  }

  foreach ($tool in @('openclaw', 'git', 'schtasks', 'icacls')) {
    if ($null -eq (Get-Command $tool -ErrorAction SilentlyContinue)) {
      Write-Output ("FALLO: herramienta ausente: {0}" -f $tool)
      exit 2
    }
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'tools'; exit = 0 })

  if (-not (Test-Path -LiteralPath $BackupDir)) {
    [void](New-Item -ItemType Directory -Path $BackupDir -Force)
  }
  if (-not (Test-Path -LiteralPath $ReceiptRoot)) {
    [void](New-Item -ItemType Directory -Path $ReceiptRoot -Force)
  }
  $evParent = Split-Path -Parent $EvidencePath
  if (-not (Test-Path -LiteralPath $evParent)) {
    [void](New-Item -ItemType Directory -Path $evParent -Force)
  }

  if (Test-GatewayUp -Url $HealthUrl) { throw 'gateway en marcha: se exige detenido' }
  [void]$commands.Add([PSCustomObject]@{ name = 'gateway-down'; exit = 0 })
  [void]$observations.Add('gateway detenido')

  $free = Get-DriveFree -Path $BackupDir
  if ($free -lt $MinFreeBytes) { throw ("espacio libre insuficiente: {0} < {1}" -f $free, $MinFreeBytes) }
  [void]$commands.Add([PSCustomObject]@{ name = 'free-space'; exit = 0 })
  [void]$observations.Add(("espacio libre: {0}" -f $free))

  if (Test-Path -LiteralPath $StagingRoot) { throw 'staging existe: se exige fresco' }
  $stParent = Split-Path -Parent $StagingRoot
  if (-not (Test-Path -LiteralPath $stParent)) { throw 'padre de staging inexistente' }
  if (-not (Test-RootsIsolated -Roots @($StagingRoot, $RuntimeRoot, $RepoRoot))) {
    throw 'staging dentro de repo o runtime'
  }
  if ($LauncherPaths.Count -eq 0) { throw 'sin launchers declarados' }
  foreach ($l in $LauncherPaths) {
    if (-not (Test-Path -LiteralPath $l -PathType Leaf)) { throw ("launcher ausente: {0}" -f $l) }
  }

  $createRaw = (& openclaw backup create --verify --output $BackupDir --json 2>&1)
  if ($LASTEXITCODE -ne 0) { throw 'backup create fallo' }
  $created = $null
  try { $created = (($createRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $created = $null }
  if ($null -eq $created -or [string]::IsNullOrEmpty($created.archivePath)) { throw 'backup create sin archivePath' }
  $archivePath = $created.archivePath
  [void]$commands.Add([PSCustomObject]@{ name = 'backup-create'; exit = 0 })
  [void]$observations.Add("archive: $archivePath")

  $verifyRaw = (& openclaw backup verify $archivePath --json 2>&1)
  if ($LASTEXITCODE -ne 0) { throw 'backup verify fallo' }
  $verdict = $null
  try { $verdict = (($verifyRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $verdict = $null }
  if ($null -eq $verdict -or ($verdict.ok -ne $true -and $verdict.verified -ne $true)) { throw 'backup verify no-ok' }
  [void]$commands.Add([PSCustomObject]@{ name = 'backup-verify'; exit = 0 })

  [void](New-Item -ItemType Directory -Path $StagingRoot -Force)
  & icacls $StagingRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' /grant:r '*S-1-5-32-544:(OI)(CI)F' 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'icacls lockdown fallo' }
  $aclRaw = (& icacls $StagingRoot 2>&1 | Out-String)
  foreach ($line in ($aclRaw -split "`r?`n")) {
    if ($line -notmatch '\(') { continue }
    if ($line -notmatch 'SYSTEM|S-1-5-18|S-1-5-32-544|Administrators|Administradores') {
      throw ("ACL abierta: {0}" -f $line.Trim())
    }
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'staging-acl'; exit = 0 })

  $restoreRaw = (& openclaw backup restore $archivePath --target $StagingRoot --json 2>&1)
  if ($LASTEXITCODE -ne 0) { throw 'backup restore fallo' }
  [void]$commands.Add([PSCustomObject]@{ name = 'backup-restore'; exit = 0 })

  $manFile = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Depth 3 -Filter 'manifest.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($manFile.Count -eq 0) { throw 'manifiesto ilegible en staging' }
  $man = $null
  try { $man = Get-Content -Raw -LiteralPath $manFile[0].FullName | ConvertFrom-Json -Depth 32 } catch { $man = $null }
  if ($null -eq $man) { throw 'manifiesto corrupto' }
  $kinds = @()
  foreach ($a in @($man.assets)) { $kinds += $a.kind }
  if ($kinds -notcontains 'state') { throw 'manifiesto sin asset state' }
  $stRaw = (& openclaw memory status --json 2>&1)
  if ($LASTEXITCODE -ne 0) { throw 'memory status fallo' }
  $agents = @()
  try { $agents = @(($stRaw | Out-String) | ConvertFrom-Json -Depth 32) } catch { $agents = @() }
  if ($agents.Count -eq 0) { throw 'sin agentes en memory status' }
  $covered = @()
  foreach ($r in @($man.agentRoots)) { $covered += $r.agentId }
  foreach ($g in $agents) {
    if ($covered -notcontains $g.agentId) { throw ("manifiesto sin agente: {0}" -f $g.agentId) }
  }
  $sqlites = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Filter '*.sqlite' -File -ErrorAction SilentlyContinue)
  $sqlBytes = [long]0
  foreach ($s in $sqlites) { $sqlBytes += $s.Length }
  if ($sqlites.Count -eq 0 -or $sqlBytes -le 0) { throw 'staging sin bases sqlite' }
  $hasCreds = ($man.credentialsIncluded -eq $true)
  if (-not $hasCreds) {
    $cf = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match 'credential' })
    $hasCreds = ($cf.Count -gt 0)
  }
  if (-not $hasCreds) { throw 'manifiesto sin credenciales' }
  foreach ($w in $ExpectedWorkspaces) {
    $wd = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Depth 4 -Directory -Filter $w -ErrorAction SilentlyContinue)
    if ($wd.Count -eq 0) { throw ("staging sin workspace: {0}" -f $w) }
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'manifest-coverage'; exit = 0 })
  [void]$observations.Add(("cobertura: {0} agentes, {1} sqlite, {2} workspaces" -f $agents.Count, $sqlites.Count, $ExpectedWorkspaces.Count))

  $bundleName = "source-$stamp.bundle"
  $bundlePath = Join-Path $BackupDir $bundleName
  & git -C $RepoRoot bundle create $bundlePath --all 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git bundle create fallo' }
  & git bundle verify $bundlePath 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git bundle verify fallo' }
  [void]$commands.Add([PSCustomObject]@{ name = 'git-bundle'; exit = 0 })
  [void]$observations.Add("bundle: $bundleName")

  $xmlPaths = New-Object System.Collections.Generic.List[string]
  foreach ($t in $TaskNames) {
    $xml = (& schtasks /query /tn $t /xml 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ("schtasks sin XML: {0}" -f $t) }
    if ($xml -notmatch '<Task ') { throw ("XML sin <Task: {0}" -f $t) }
    $safe = ($t -replace '[^A-Za-z0-9]+', '-').Trim('-')
    $xp = Join-Path $BackupDir ("task-{0}-{1}.xml" -f $safe, $stamp)
    [IO.File]::WriteAllText($xp, $xml, (New-Object Text.UTF8Encoding $false))
    [void]$xmlPaths.Add($xp)
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'task-xml'; exit = 0 })

  $launcherCopies = New-Object System.Collections.Generic.List[string]
  $li = 0
  foreach ($l in $LauncherPaths) {
    $li++
    $dest = Join-Path $BackupDir ("launcher-{0}-{1}" -f $li, (Split-Path -Leaf $l))
    Copy-Item -LiteralPath $l -Destination $dest -Force
    [void]$launcherCopies.Add($dest)
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'launchers'; exit = 0 })

  foreach ($c in $InventoryPaths) {
    if (-not (Test-Path -LiteralPath $c)) { throw ("candidato inexistente: {0}" -f $c) }
  }
  $invPath = Join-Path $BackupDir ("runtime-inventory-{0}.jsonl" -f $stamp)
  $invLines = New-Object System.Collections.Generic.List[string]
  $allInv = New-Object System.Collections.Generic.List[string]
  foreach ($c in $InventoryPaths) { [void]$allInv.Add($c) }
  [void]$allInv.Add($archivePath)
  [void]$allInv.Add($bundlePath)
  foreach ($x in $xmlPaths) { [void]$allInv.Add($x) }
  foreach ($x in $launcherCopies) { [void]$allInv.Add($x) }
  foreach ($p in $allInv) {
    $esc = $p.Replace('\', '\\').Replace('"', '\"')
    [void]$invLines.Add(('{"path":"' + $esc + '","sizeBytes":' + (Get-Item -LiteralPath $p).Length + ',"sha256":"' + (Get-FileSha -Path $p) + '"}'))
  }
  [IO.File]::WriteAllLines($invPath, $invLines.ToArray(), (New-Object Text.UTF8Encoding $false))
  [void]$commands.Add([PSCustomObject]@{ name = 'inventory'; exit = 0 })
  [void]$observations.Add(("inventario: {0} rutas" -f $allInv.Count))

  Remove-Item -LiteralPath $StagingRoot -Recurse -Force
  [void]$observations.Add('staging de prueba removido tras verificar')
} catch {
  $failed = $true
  $failWhy = $_.Exception.Message
}

$archiveSize = [long]0
$archiveSha = ''
if (-not [string]::IsNullOrEmpty($archivePath) -and (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
  $archiveSize = (Get-Item -LiteralPath $archivePath).Length
  $archiveSha = Get-FileSha -Path $archivePath
}
$ev = [ordered]@{
  archivePath = $archivePath; sizeBytes = $archiveSize; sha256 = $archiveSha
  createdUtc = (Get-UtcNow); passed = (-not $failed)
}
$evJson = (New-Object PSObject -Property $ev) | ConvertTo-Json -Compress
$evTmp = $EvidencePath + '.tmp-' + [Guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText($evTmp, $evJson, (New-Object Text.UTF8Encoding $false))
Move-Item -LiteralPath $evTmp -Destination $EvidencePath -Force

$h = @{ startupz = 0; readyz = 0 }
$obs = $observations.ToArray()
if ($failed) {
  $why = $failWhy
  if ([string]::IsNullOrEmpty($why)) { $why = 'falla sin motivo' }
  if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
  $obs = @("FALLO: $why") + $obs
}
if ($obs.Count -eq 0) { $obs = @('respaldo verificado') }
if ($obs.Count -gt 20) { $obs = $obs[0..19] }
$hostName = $env:COMPUTERNAME
if ([string]::IsNullOrEmpty($hostName)) { $hostName = (& hostname) }
if ($hostName.Length -gt 128) { $hostName = $hostName.Substring(0, 128) }
$result = 'passed'
if ($failed) { $result = 'failed' }
$rbArtifact = $archivePath
if ([string]::IsNullOrEmpty($rbArtifact)) { $rbArtifact = 'none' }
$srcSha = '0' * 40
try {
  $r = (& git -C $RepoRoot rev-parse HEAD 2>$null)
  if ($r -match '^[0-9a-f]{40}$') { $srcSha = $r }
} catch { }
$inputs = [ordered]@{}
if ($archiveSha -match '^[0-9a-f]{64}$') {
  $inputs['archive'] = [ordered]@{ algo = 'sha256'; sha256 = $archiveSha }
}
$doc = [ordered]@{
  schema = 'runtime-separation-receipt.v1'; phase = '16'
  startedAt = $startedAt; endedAt = (Get-UtcNow)
  sourceSha = $srcSha; host = $hostName; openclawVersion = $ver
  commands = $commands.ToArray(); inputs = $inputs
  observations = $obs
  health = [ordered]@{ startupz = $h['startupz']; readyz = $h['readyz'] }
  result = $result
  rollback = [ordered]@{ artifact = $rbArtifact; deadlineUtc = ([DateTime]::UtcNow.AddDays(30).ToString('yyyy-MM-ddTHH:mm:ssZ')) }
}
$receiptSchema = Join-Path $PSScriptRoot '../../docs/spec/runtime-separation-receipt.v1.schema.json'
$json = (New-Object PSObject -Property $doc) | ConvertTo-Json -Depth 5 -Compress
$name = 'backup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
  [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json'
Write-ReceiptAtomic -ReceiptJson $json -Path (Join-Path $ReceiptRoot $name) -SchemaPath $receiptSchema

if ($failed) {
  Write-Output ("FALLO: {0}" -f $failWhy)
  exit 1
}
exit 0
