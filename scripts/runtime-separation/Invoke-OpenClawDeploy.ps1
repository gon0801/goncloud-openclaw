# Invoke-OpenClawDeploy.ps1 — despliegue por manifiesto (Fase 16, Task 2).
#
# Sin -Apply es report-only: prepara staging, valida y reporta; no toca
# runtime ni escribe recibo. Con -Apply exige las cuatro raices, valida
# staging (clasificacion, parseo PS, compuerta httpTimeoutSec, streams),
# valida config ANTES de publicar (cero escrituras si falla), respalda
# solo reemplazos, publica en orden alfabetico con reemplazo atomico por
# archivo, re-lee por hash, sondea salud y revierte el conjunto del recibo
# ante cualquier fallo. Salidas: 0 exito, 1 validacion, 2 revertido,
# 3 reversa fallida. El runtime jamas se toca con git: sin resets duros
# ni pulls dentro del estado vivo. OPENCLAW_DEPLOY_FAULT=readback|journal
# inyecta fallos solo de prueba tras el reemplazo (nunca en produccion).
param(
  [Parameter(Mandatory = $true)][string]$SourceRoot,
  [Parameter(Mandatory = $true)][string]$ManifestPath,
  [string]$RuntimeRoot = $null,
  [string]$StagingRoot = $null,
  [string]$ReceiptRoot = $null,
  [string]$HealthUrl = 'http://127.0.0.1:18789',
  [string[]]$ExcludePaths = @(),
  [string]$OpenClawVersion = $null,
  [string]$SourceSha = $null,
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeSeparation.psm1') -Force

function Write-JournalLine {
  param([string]$JournalPath, [string]$Op, [string]$Path, [string]$Sha)
  if ($env:OPENCLAW_DEPLOY_FAULT -ceq 'journal' -and $Op -ceq 'replace') {
    throw 'falla inyectada: journal'
  }
  $esc = $Path.Replace('\', '\\').Replace('"', '\"')
  $line = '{"op":"' + $Op + '","path":"' + $esc + '","sha256":"' + $Sha + '"}'
  Add-Content -LiteralPath $JournalPath -Value $line
}

function Get-UtcNow { return ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) }

$startedAt = Get-UtcNow
$commands = New-Object System.Collections.Generic.List[object]
function Add-Command([string]$Name, [int]$Exit) {
  [void]$commands.Add([PSCustomObject]@{ name = $Name; exit = $Exit })
}
$observations = New-Object System.Collections.Generic.List[string]
function Add-Observation([string]$Text) {
  $t = $Text
  if ($t.Length -gt 300) { $t = $t.Substring(0, 300) }
  [void]$observations.Add($t)
}

$schemaPath = Join-Path $PSScriptRoot '../../docs/spec/runtime-separation-receipt.v1.schema.json'
$receiptSchema = $schemaPath
if (-not (Test-Path -LiteralPath $receiptSchema)) {
  $receiptSchema = Join-Path (Get-Location) 'docs/spec/runtime-separation-receipt.v1.schema.json'
}

function Write-DeployReceipt {
  param([string]$Result, [hashtable]$Health, [string]$Artifact, [string]$Deadline,
        [hashtable]$Inputs, [string]$DestDir)
  if (-not (Test-Path -LiteralPath $DestDir)) {
    [void](New-Item -ItemType Directory -Path $DestDir -Force)
  }
  $obs = $observations.ToArray()
  if ($obs.Count -gt 20) { $obs = $obs[0..19] }
  $doc = [ordered]@{
    schema = 'runtime-separation-receipt.v1'; phase = '16'
    startedAt = $startedAt; endedAt = (Get-UtcNow)
    sourceSha = $script:resolvedSha; host = $script:resolvedHost
    openclawVersion = $script:resolvedVersion
    commands = $commands.ToArray(); inputs = $Inputs; observations = $obs
    health = [ordered]@{ startupz = $Health['startupz']; readyz = $Health['readyz'] }
    result = $Result
    rollback = [ordered]@{ artifact = $Artifact; deadlineUtc = $Deadline }
  }
  $json = (New-Object PSObject -Property $doc) | ConvertTo-Json -Depth 5 -Compress
  $name = 'deploy-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
    [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json'
  Write-ReceiptAtomic -ReceiptJson $json -Path (Join-Path $DestDir $name) -SchemaPath $receiptSchema
  return $name
}

function Resolve-Identity {
  if ([string]::IsNullOrEmpty($SourceSha)) {
    try {
      $sha = (& git -C $SourceRoot rev-parse HEAD 2>$null)
      if ($sha -cmatch '^[0-9a-f]{40}$') { $script:resolvedSha = $sha }
      else { $script:resolvedSha = ('0' * 40); Add-Observation 'source sin sha git: ceros' }
    } catch {
      $script:resolvedSha = ('0' * 40); Add-Observation 'source sin git: ceros'
    }
  } else {
    $script:resolvedSha = $SourceSha
  }
  if ([string]::IsNullOrEmpty($OpenClawVersion)) {
    $v = (& openclaw --version 2>&1 | Out-String)
    $m = [regex]::Match($v, '(\d{4}\.\d+\.\d+)')
    if (-not $m.Success) { throw 'version openclaw irresoluble' }
    $script:resolvedVersion = $m.Groups[1].Value
  } else {
    $script:resolvedVersion = $OpenClawVersion
  }
  if (-not [string]::IsNullOrEmpty($env:COMPUTERNAME)) { $script:resolvedHost = $env:COMPUTERNAME }
  else { $script:resolvedHost = (& hostname) }
  if ($script:resolvedHost.Length -gt 128) { $script:resolvedHost = $script:resolvedHost.Substring(0, 128) }
}

try {
  Resolve-Identity
} catch {
  Write-Output ("identidad irresoluble: " + $_.Exception.Message)
  exit 1
}

$health = @{ startupz = 0; readyz = 0 }
$deadline = ([DateTime]::UtcNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ'))
$inputs = @{}

if ($Apply -and ([string]::IsNullOrEmpty($RuntimeRoot) -or [string]::IsNullOrEmpty($StagingRoot) -or [string]::IsNullOrEmpty($ReceiptRoot))) {
  Write-Output '-Apply exige SourceRoot, RuntimeRoot, StagingRoot y ReceiptRoot'
  exit 1
}
if ([string]::IsNullOrEmpty($StagingRoot)) {
  $StagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('deploy-staging-' + [Guid]::NewGuid().ToString('N'))
}
$checkRoots = @($SourceRoot, $StagingRoot)
if (-not [string]::IsNullOrEmpty($RuntimeRoot)) { $checkRoots += $RuntimeRoot }
if (-not [string]::IsNullOrEmpty($ReceiptRoot)) { $checkRoots += $ReceiptRoot }
if (-not (Test-RootsIsolated -Roots $checkRoots)) {
  Write-Output 'raices traslapadas o relativas: cero escrituras'
  Add-Command 'roots' 1
  $safeReceipt = $false
  if (-not [string]::IsNullOrEmpty($ReceiptRoot)) {
    $safeReceipt = Test-RootsIsolated -Roots @($SourceRoot, $StagingRoot, $ReceiptRoot)
  }
  if ($Apply -and $safeReceipt) {
    Write-DeployReceipt -Result 'failed' -Health $health -Artifact 'none' -Deadline $deadline -Inputs $inputs -DestDir $ReceiptRoot
  }
  exit 1
}
Add-Command 'roots' 0

$excl = @()
foreach ($x in $ExcludePaths) { $excl += $x.Replace('\', '/').ToLowerInvariant() }

$stageList = New-Object System.Collections.Generic.List[object]
$srcFiles = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force | Sort-Object FullName)
foreach ($f in $srcFiles) {
  if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    Write-Output ("reparse en fuente: " + $f.FullName)
    Add-Command 'stage' 1
    if ($Apply) {
      Write-DeployReceipt -Result 'failed' -Health $health -Artifact 'none' -Deadline $deadline -Inputs $inputs -DestDir $ReceiptRoot
    }
    exit 1
  }
  $rel = $f.FullName.Substring($SourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
  $veredict = Test-DeployPathClassification -RelativePath $rel -ManifestPath $ManifestPath
  if ($veredict -ne 'deployable') { continue }
  if ($excl -contains $rel.ToLowerInvariant()) {
    Add-Observation ("excluido: " + $rel)
    continue
  }
  [void]$stageList.Add([PSCustomObject]@{ Rel = $rel; Full = $f.FullName })
}
Add-Command 'stage' 0
Add-Observation ("candidatos: " + $stageList.Count)

if (Test-Path -LiteralPath $StagingRoot) {
  Remove-Item -LiteralPath $StagingRoot -Recurse -Force
}
[void](New-Item -ItemType Directory -Path $StagingRoot -Force)
$journal = Join-Path $StagingRoot 'journal.jsonl'
foreach ($e in $stageList) {
  $dest = Join-Path $StagingRoot ($e.Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
  $dd = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $dd)) { [void](New-Item -ItemType Directory -Path $dd -Force) }
  Copy-Item -LiteralPath $e.Full -Destination $dest -Force
  $sha = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
  Write-JournalLine -JournalPath $journal -Op 'stage' -Path $e.Rel -Sha $sha
}

$valid = $true
$stagedPs = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File -Force | Where-Object { $_.Extension -eq '.ps1' })
foreach ($s in $stagedPs) {
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errs)
  if ($errs.Count -gt 0) {
    Write-Output ("parseo PS falla: " + $s.FullName)
    $valid = $false
  }
  $txt = Get-Content -Raw -LiteralPath $s.FullName
  if ($txt -match '\$httpTimeoutSec') {
    if (-not (Test-EffectiveHttpTimeout -Path $s.FullName)) {
      Write-Output ("compuerta timeout falla: " + $s.FullName)
      $valid = $false
    }
  }
}
foreach ($s in @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File -Force)) {
  try {
    $streams = @(Get-Item -LiteralPath $s.FullName -Stream * -ErrorAction Stop | Where-Object { $_.Stream -ne ':$DATA' })
    if ($streams.Count -gt 0) {
      Write-Output ("streams ADS inesperados: " + $s.FullName)
      $valid = $false
    }
  } catch {
    Add-Observation 'streams no verificables en esta plataforma'
    break
  }
}
if (-not $valid) {
  Add-Command 'validate' 1
  if ($Apply) {
    Write-DeployReceipt -Result 'failed' -Health $health -Artifact 'none' -Deadline $deadline -Inputs $inputs -DestDir $ReceiptRoot
  } else {
    Write-Output 'WhatIf: el candidato NO pasaria validacion'
  }
  exit 1
}
Add-Command 'validate' 0
$cfgOut = (& openclaw config validate 2>&1 | Out-String)
if (($LASTEXITCODE -ne 0) -or ($cfgOut -notmatch 'Config valid')) {
  Add-Command 'config-validate' 1
  if ($Apply) {
    Write-DeployReceipt -Result 'failed' -Health $health -Artifact 'none' -Deadline $deadline -Inputs $inputs -DestDir $ReceiptRoot
  } else {
    Write-Output 'WhatIf: config validate no acepta'
  }
  exit 1
}
Add-Command 'config-validate' 0

if (-not $Apply) {
  Write-Output ("WhatIf: " + $stageList.Count + " archivo(s) pasarian validacion; runtime intacto, sin recibo")
  exit 0
}

$backupDir = Join-Path $StagingRoot 'backup'
[void](New-Item -ItemType Directory -Path $backupDir -Force)
$plan = New-Object System.Collections.Generic.List[object]
foreach ($e in ($stageList | Sort-Object Rel)) {
  $target = Join-Path $RuntimeRoot ($e.Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
  $staged = Join-Path $StagingRoot ($e.Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
  $stSha = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
  $exists = Test-Path -LiteralPath $target
  $same = $false
  if ($exists -and -not (Get-Item -LiteralPath $target).PSIsContainer) {
    $rtSha = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    $same = ($rtSha -ceq $stSha)
  }
  if ($same) {
    Write-JournalLine -JournalPath $journal -Op 'skip' -Path $e.Rel -Sha $stSha
    continue
  }
  if ($exists -and -not (Get-Item -LiteralPath $target).PSIsContainer) {
    $bd = Join-Path $backupDir ($e.Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $bp = Split-Path -Parent $bd
    if (-not (Test-Path -LiteralPath $bp)) { [void](New-Item -ItemType Directory -Path $bp -Force) }
    Copy-Item -LiteralPath $target -Destination $bd -Force
    Write-JournalLine -JournalPath $journal -Op 'backup' -Path $e.Rel -Sha $rtSha
  }
  [void]$plan.Add([PSCustomObject]@{ Rel = $e.Rel; Target = $target; Staged = $staged; Sha = $stSha; Existed = $exists })
  $inputs[$e.Rel] = @{ algo = 'sha256'; sha256 = $stSha }
}
Add-Command 'backup' 0
Add-Observation ("a publicar: " + $plan.Count)

$published = New-Object System.Collections.Generic.List[object]
$phase = 'replace'
try {
  foreach ($p in $plan) {
    if ((Test-Path -LiteralPath $p.Target) -and (Get-Item -LiteralPath $p.Target).PSIsContainer) {
      throw ("destino es directorio: " + $p.Rel)
    }
    $tmp = $p.Target + '.tmp-' + [Guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $p.Staged -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $p.Target -Force
    [void]$published.Add($p)
    if ($env:OPENCLAW_DEPLOY_FAULT -ceq 'readback') {
      throw 'falla inyectada: read-back'
    }
    if (-not (Test-HashEqual -Path $p.Target -ExpectedSha256 $p.Sha)) {
      throw ("re-lectura difiere: " + $p.Rel)
    }
    Write-JournalLine -JournalPath $journal -Op 'replace' -Path $p.Rel -Sha $p.Sha
  }
  Add-Command 'replace' 0
  $phase = 'probes'
  $sondas = [ordered]@{ startupz = '/startupz'; readyz = '/readyz' }
  foreach ($k in $sondas.Keys) {
    try {
      $r = Invoke-WebRequest -Uri ($HealthUrl + $sondas[$k]) -TimeoutSec 10 -UseBasicParsing
      $health[$k] = [int]$r.StatusCode
    } catch {
      $health[$k] = 0
    }
    if ($health[$k] -ne 200) { throw ("sonda $k no da 200") }
  }
  Add-Command 'probes' 0
} catch {
  Write-Output ("fallo en publicacion: " + $_.Exception.Message)
  Add-Command $phase 1
  try {
    for ($i = $published.Count - 1; $i -ge 0; $i--) {
      $p = $published[$i]
      if ($p.Existed) {
        $bd = Join-Path $backupDir ($p.Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $tmp = $p.Target + '.tmp-' + [Guid]::NewGuid().ToString('N')
        Copy-Item -LiteralPath $bd -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $p.Target -Force
        Write-JournalLine -JournalPath $journal -Op 'rollback' -Path $p.Rel -Sha ''
      } else {
        Remove-Item -LiteralPath $p.Target -Force
        Write-JournalLine -JournalPath $journal -Op 'rollback-delete' -Path $p.Rel -Sha ''
      }
    }
    Write-DeployReceipt -Result 'rolled_back' -Health $health -Artifact $backupDir -Deadline $deadline -Inputs $inputs -DestDir $ReceiptRoot
    exit 2
  } catch {
    Write-Output ("reversa fallida: " + $_.Exception.Message)
    Write-DeployReceipt -Result 'failed' -Health $health -Artifact $backupDir -Deadline $deadline -Inputs $inputs -DestDir $ReceiptRoot
    exit 3
  }
}

Write-DeployReceipt -Result 'passed' -Health $health -Artifact $backupDir -Deadline $deadline -Inputs $inputs -DestDir $ReceiptRoot
exit 0
