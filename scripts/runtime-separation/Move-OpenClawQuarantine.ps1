# Move-OpenClawQuarantine.ps1 — cuarentena reversible (Fase 16, Task 6).
#
# Sin -Apply es report-only: valida, imprime el plan y no mueve nada. Con
# -Apply y -Mode move hashea e inventaria cada candidato ANTES de moverlo a
# una raiz fresca fuera del repo y del runtime, persiste recovery.jsonl con
# fsync ANTES de cada movimiento, re-hashea despues y registra ruta/hash.
# Rechaza bases de datos, WAL/SHM, credenciales, sesiones, launchers
# activos, evidencia, handles abiertos y worktrees sin cerrar, y candidatos
# ancestros de las raices. No existe comando de borrado en este archivo.
# -Mode restore canoniza rutas, exige quarantinePath dentro de la raiz,
# valida TODO el inventario antes del primer movimiento y rechaza
# duplicados, campos desconocidos y reparse points; si el origen esta
# ocupado frena. Salidas: 0 ok, 1 freno, 2 herramienta ausente.
param(
  [string[]]$CandidatePaths = @(),
  [Parameter(Mandatory = $true)][string]$QuarantineRoot,
  [Parameter(Mandatory = $true)][string]$RepoRoot,
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [Parameter(Mandatory = $true)][string]$ReceiptRoot,
  [Parameter(Mandatory = $true)][string]$InventoryPath,
  [string[]]$ActiveLaunchers = @(),
  [string[]]$EvidencePaths = @(),
  [ValidateSet('move', 'restore')][string]$Mode = 'move',
  [string]$RestoreOnly = '',
  [int]$MaxProbeFiles = 1000,
  [string]$OpenClawVersion = '',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeSeparation.psm1') -Force

# CLI (-File) no arma arrays: aceptar elementos unidos con ';'.
$CandidatePaths = @($CandidatePaths | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })
$ActiveLaunchers = @($ActiveLaunchers | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })
$EvidencePaths = @($EvidencePaths | ForEach-Object { $_ -split ';' } | Where-Object { $_ -ne '' })

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
function Get-Full([string]$Path) {
  return [IO.Path]::GetFullPath($Path)
}
function Get-RawLineString([string]$Line, [string]$Key) {
  $m = [regex]::Match($Line, '"' + $Key + '"\s*:\s*"([^"]*)"')
  if (-not $m.Success) { return $null }
  return $m.Groups[1].Value
}
function Get-DirSha([string]$Root) {
  $df = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)
  $fp = New-Object System.Collections.Generic.List[string]
  foreach ($f in ($df | Sort-Object { $_.FullName })) {
    $rel = $f.FullName.Substring($Root.Length)
    [void]$fp.Add(("{0}|{1}|{2}" -f $rel, $f.Length, (Get-FileSha -Path $f.FullName)))
  }
  $joined = [string]::Join("`n", $fp.ToArray())
  $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
  } finally {
    $hasher.Dispose()
  }
}
function ConvertTo-InventoryLine([string]$Original, [string]$Dest, [string]$Kind,
    [long]$Size, [string]$Sha, [long]$Count, [string]$Stamp) {
  $eo = $Original.Replace('\', '\\').Replace('"', '\"')
  $ed = $Dest.Replace('\', '\\').Replace('"', '\"')
  return ('{"originalPath":"' + $eo + '","quarantinePath":"' + $ed +
    '","kind":"' + $Kind + '","sizeBytes":' + $Size + ',"sha256":"' + $Sha +
    '","fileCount":' + $Count + ',"movedUtc":"' + $Stamp + '"}')
}
function Write-RecoveryLine([string]$LogPath, [string]$Line) {
  $dir = Split-Path -Parent $LogPath
  if (-not (Test-Path -LiteralPath $dir)) {
    [void](New-Item -ItemType Directory -Path $dir -Force)
  }
  $fs = [IO.File]::Open($LogPath, [IO.FileMode]::Append,
    [IO.FileAccess]::Write, [IO.FileShare]::Read)
  try {
    $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($Line + "`n")
    $fs.Write($bytes, 0, $bytes.Length)
    $fs.Flush($true)
  } finally {
    $fs.Dispose()
  }
}
function Test-HandleOpen([string]$Path) {
  $isWin = ([Environment]::OSVersion.Platform -eq 'Win32NT')
  if ($isWin) {
    try {
      $s = [IO.File]::Open($Path, 'Open', 'Read', 'None')
      $s.Close()
      $s.Dispose()
      return $false
    } catch {
      return $true
    }
  }
  $flock = Get-Command 'flock' -ErrorAction SilentlyContinue
  if ($null -ne $flock) {
    & flock -n $Path true 2>&1 | Out-Null
    return ($LASTEXITCODE -ne 0)
  }
  return $false
}

$startedAt = Get-UtcNow
$commands = New-Object System.Collections.Generic.List[object]
$observations = New-Object System.Collections.Generic.List[string]
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$failed = $false
$failWhy = ''
$moved = New-Object System.Collections.Generic.List[object]
$probeWarned = $false

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
  if ($null -eq (Get-Command 'openclaw' -ErrorAction SilentlyContinue)) {
    if ($Apply) {
      Write-Output 'FALLO: herramienta ausente: openclaw'
      exit 2
    }
  }

  $qFull = Get-Full -Path $QuarantineRoot
  $repoFull = Get-Full -Path $RepoRoot
  $rtFull = Get-Full -Path $RuntimeRoot
  $launchFull = @($ActiveLaunchers | ForEach-Object { Get-Full -Path $_ })
  $evFull = @($EvidencePaths | ForEach-Object { Get-Full -Path $_ })

  if ($Mode -ceq 'move') {
    $rbArtifact = $QuarantineRoot
    if ($CandidatePaths.Count -eq 0) { throw 'sin candidatos' }
    if ($Apply) {
      if (Test-Path -LiteralPath $QuarantineRoot) { throw 'cuarentena existe: se exige fresca' }
      $qParent = Split-Path -Parent $QuarantineRoot
      if (-not (Test-Path -LiteralPath $qParent)) { throw 'padre de cuarentena inexistente' }
      if (-not (Test-RootsIsolated -Roots @($QuarantineRoot, $RepoRoot, $RuntimeRoot))) {
        throw 'cuarentena dentro de repo o runtime'
      }
    }

    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($c in $CandidatePaths) {
      if (-not (Test-Path -LiteralPath $c)) { throw ("ausente: {0}" -f $c) }
      $full = Get-Full -Path $c
      $sep = [IO.Path]::DirectorySeparatorChar
      foreach ($r in @($repoFull, $rtFull, $qFull)) {
        if ($full -ceq $r -or $r.StartsWith($full + $sep, [StringComparison]::OrdinalIgnoreCase)) {
          throw ("ancestro de raiz: {0}" -f $c)
        }
      }
      $isDir = Test-Path -LiteralPath $c -PathType Container
      $files = @()
      if ($isDir) {
        $files = @(Get-ChildItem -LiteralPath $c -Recurse -File -Force -ErrorAction SilentlyContinue)
      } else {
        $files = @((Get-Item -LiteralPath $c -Force))
      }
      if ($files.Count -gt $MaxProbeFiles) { throw ("demasiados archivos: {0}" -f $c) }
      foreach ($f in $files) {
        $rel = $f.FullName
        $norm = $rel.Replace('\', '/')
        $leaf = $f.Name
        $ext = [IO.Path]::GetExtension($leaf)
        if (@('.db', '.sqlite', '.sqlite3') -contains $ext.ToLowerInvariant()) {
          throw ("base de datos: {0}" -f $rel)
        }
        if ($leaf -match '-wal$|-shm$|-journal$') { throw ("wal/shm: {0}" -f $rel) }
        if ($leaf -match 'credential|secret' -or $ext.ToLowerInvariant() -ceq '.env' -or $leaf -like '.env*') {
          throw ("credencial: {0}" -f $rel)
        }
        if ($norm -match '/sessions/') { throw ("sesion: {0}" -f $rel) }
        $fFull = Get-Full -Path $f.FullName
        if ($launchFull -contains $fFull) { throw ("launcher activo: {0}" -f $rel) }
        if ($evFull -contains $fFull) { throw ("evidencia: {0}" -f $rel) }
        if ($leaf -ceq '.git' -and !(Test-Path -LiteralPath $f.FullName -PathType Container)) {
          throw ("worktree sin cerrar: {0}" -f $rel)
        }
        if (Test-HandleOpen -Path $f.FullName) { throw ("handle abierto: {0}" -f $rel) }
      }
      if (-not ([Environment]::OSVersion.Platform -eq 'Win32NT') -and
          ($null -eq (Get-Command 'flock' -ErrorAction SilentlyContinue)) -and -not $probeWarned) {
        [void]$observations.Add('sin sonda de handles (sin flock); el SO frena el move si hay lock')
        $probeWarned = $true
      }
      $kind = 'file'
      $size = [long]0
      $sha = ''
      if ($isDir) {
        $kind = 'dir'
        foreach ($f in $files) { $size += $f.Length }
        $sha = Get-DirSha -Root $full
      } else {
        $size = (Get-Item -LiteralPath $c).Length
        $sha = Get-FileSha -Path $c
      }
      [void]$plan.Add([PSCustomObject]@{
          Original = $full; Kind = $kind; Size = $size; Sha = $sha; Count = $files.Count
        })
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'validate'; exit = 0 })
    [void]$observations.Add(("candidatos validados: {0}" -f $plan.Count))

    if (-not $Apply) {
      foreach ($p in $plan) {
        Write-Output ("plan mover: {0} {1} {2}B {3}" -f $p.Kind, $p.Original, $p.Size, $p.Sha.Substring(0, 12))
      }
      foreach ($o in $observations) { Write-Output ("plan: observacion: {0}" -f $o) }
      exit 0
    }

    [void](New-Item -ItemType Directory -Path $QuarantineRoot -Force)
    $recoveryLog = Join-Path $QuarantineRoot 'recovery.jsonl'
    foreach ($p in $plan) {
      $leaf = Split-Path -Leaf $p.Original
      $dest = Join-Path $QuarantineRoot ("{0}-{1}-{2}" -f $leaf, $stamp,
        [Guid]::NewGuid().ToString('N').Substring(0, 4))
      Write-RecoveryLine -LogPath $recoveryLog -Line (ConvertTo-InventoryLine `
        -Original $p.Original -Dest $dest -Kind $p.Kind -Size $p.Size `
        -Sha $p.Sha -Count $p.Count -Stamp (Get-UtcNow))
      if ($env:OPENCLAW_QUARANTINE_FAULT -ceq 'pre-move-crash') { Start-Sleep -Seconds 30 }
      Move-Item -LiteralPath $p.Original -Destination $dest -Force
      if (Test-Path -LiteralPath $p.Original) { throw ("origen sigue: {0}" -f $p.Original) }
      $reSha = ''
      if ($p.Kind -ceq 'dir') {
        $reSha = Get-DirSha -Root $dest
      } else {
        $reSha = Get-FileSha -Path $dest
      }
      if ($reSha -cne $p.Sha) { throw ("hash distinto tras mover: {0}" -f $p.Original) }
      [void]$moved.Add([PSCustomObject]@{
          Original = $p.Original; Dest = $dest; Kind = $p.Kind; Size = $p.Size
          Sha = $p.Sha; Count = $p.Count
        })
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'move'; exit = 0 })
  } else {
    $rbArtifact = $QuarantineRoot
    if ([string]::IsNullOrEmpty($InventoryPath) -or !(Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
      throw 'restore exige inventario'
    }
    if (-not (Test-Path -LiteralPath $QuarantineRoot -PathType Container)) {
      throw 'restore exige raiz de cuarentena'
    }
    $rbArtifact = $InventoryPath
    $entries = New-Object System.Collections.Generic.List[object]
    $wantKeys = @('originalPath', 'quarantinePath', 'kind', 'sizeBytes',
      'sha256', 'fileCount', 'movedUtc')
    $seenO = @{}
    $seenQ = @{}
    $rsep = [IO.Path]::DirectorySeparatorChar
    foreach ($line in (Get-Content -LiteralPath $InventoryPath -Encoding UTF8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $e = $null
      try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw 'inventario corrupto' }
      $got = @($e.PSObject.Properties.Name)
      if ($got.Count -ne $wantKeys.Count) { throw 'inventario corrupto' }
      foreach ($k in $wantKeys) {
        if ($got -notcontains $k) { throw 'inventario corrupto' }
      }
      if (@('file', 'dir') -notcontains $e.kind) { throw 'inventario corrupto' }
      try { $sz = [long]$e.sizeBytes; $fc = [long]$e.fileCount } catch { throw 'inventario corrupto' }
      if ($sz -lt 0 -or $fc -lt 0) { throw 'inventario corrupto' }
      if ($e.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'inventario corrupto' }
      $rawTs = Get-RawLineString -Line $line -Key 'movedUtc'
      if ($null -eq $rawTs -or $rawTs -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') {
        throw 'inventario corrupto'
      }
      if ([string]::IsNullOrEmpty($e.originalPath) -or
          [string]::IsNullOrEmpty($e.quarantinePath)) { throw 'inventario corrupto' }
      $oq = Get-Full -Path $e.originalPath
      $qq = Get-Full -Path $e.quarantinePath
      if (-not $qq.StartsWith($qFull + $rsep, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("cuarentena fuera de raiz: {0}" -f $e.quarantinePath)
      }
      if (-not [string]::IsNullOrEmpty($RestoreOnly)) {
        if ($oq -cne (Get-Full -Path $RestoreOnly)) { continue }
      }
      if ($seenO.ContainsKey($oq) -or $seenQ.ContainsKey($qq)) { throw 'inventario duplicado' }
      $seenO[$oq] = $true
      $seenQ[$qq] = $true
      [void]$entries.Add([PSCustomObject]@{
          O = $oq; Q = $qq; Kind = [string]$e.kind; Size = $sz
          Sha = [string]$e.sha256; Count = $fc
        })
    }
    if ($entries.Count -eq 0) { throw 'restore sin entradas' }
    [void]$commands.Add([PSCustomObject]@{ name = 'restore-load'; exit = 0 })
    $rSha = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$observations.Add(("inventario sha256: {0}" -f $rSha))

    foreach ($en in $entries) {
      if (-not (Test-Path -LiteralPath $en.Q)) {
        throw ("cuarentena sin ruta: {0}" -f $en.Q)
      }
      $qi = Get-Item -LiteralPath $en.Q -Force
      if (($qi.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ("reparse en cuarentena: {0}" -f $en.Q)
      }
      $cur = ''
      if ($en.Kind -ceq 'dir') {
        $cur = Get-DirSha -Root $en.Q
      } else {
        $cur = Get-FileSha -Path $en.Q
      }
      if ($cur -cne $en.Sha) { throw ("hash distinto en cuarentena: {0}" -f $en.O) }
      if (Test-Path -LiteralPath $en.O) { throw ("origen ocupado: {0}" -f $en.O) }
      $parent = Split-Path -Parent $en.O
      if ((Test-Path -LiteralPath $parent) -and
          (((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ("reparse en destino: {0}" -f $parent)
      }
    }

    if (-not $Apply) {
      foreach ($en in $entries) {
        Write-Output ("plan restore: {0} <- {1}" -f $en.O, $en.Q)
      }
      exit 0
    }

    foreach ($en in $entries) {
      $parent = Split-Path -Parent $en.O
      if (-not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
      }
      Move-Item -LiteralPath $en.Q -Destination $en.O -Force
      if (-not (Test-Path -LiteralPath $en.O)) { throw ("restore sin destino: {0}" -f $en.O) }
      [void]$moved.Add([PSCustomObject]@{
          Original = $en.O; Dest = $en.O; Kind = $en.Kind
          Size = $en.Size; Sha = $en.Sha; Count = $en.Count
        })
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'restore'; exit = 0 })
    [void]$observations.Add(("restaurados: {0}" -f $moved.Count))
  }
} catch {
  $failed = $true
  $failWhy = $_.Exception.Message
}

if ($Mode -ceq 'move' -and $Apply -and $moved.Count -gt 0) {
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($m in $moved) {
    [void]$lines.Add((ConvertTo-InventoryLine -Original $m.Original -Dest $m.Dest `
      -Kind $m.Kind -Size $m.Size -Sha $m.Sha -Count $m.Count -Stamp (Get-UtcNow)))
  }
  $invParent = Split-Path -Parent $InventoryPath
  if (-not (Test-Path -LiteralPath $invParent)) {
    [void](New-Item -ItemType Directory -Path $invParent -Force)
  }
  $invTmp = $InventoryPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
  [IO.File]::WriteAllLines($invTmp, $lines.ToArray(), (New-Object Text.UTF8Encoding $false))
  Move-Item -LiteralPath $invTmp -Destination $InventoryPath -Force
  $invSha = (Get-FileHash -LiteralPath $InventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
  [void]$observations.Add(("inventario sha256: {0}" -f $invSha))
}

$obs = $observations.ToArray()
if ($failed) {
  $why = $failWhy
  if ([string]::IsNullOrEmpty($why)) { $why = 'falla sin motivo' }
  if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
  $obs = @("FALLO: $why") + $obs
}
if ($obs.Count -eq 0) { $obs = @('cuarentena lista') }
if ($obs.Count -gt 20) { $obs = $obs[0..19] }
$hostName = $env:COMPUTERNAME
if ([string]::IsNullOrEmpty($hostName)) { $hostName = (& hostname) }
if ($hostName.Length -gt 128) { $hostName = $hostName.Substring(0, 128) }
$result = 'passed'
if ($failed) { $result = 'failed' }
$srcSha = '0' * 40
try {
  $r = (& git -C $RepoRoot rev-parse HEAD 2>$null)
  if ($r -match '^[0-9a-f]{40}$') { $srcSha = $r }
} catch { }
if (-not (Test-Path -LiteralPath $ReceiptRoot)) {
  [void](New-Item -ItemType Directory -Path $ReceiptRoot -Force)
}
$doc = [ordered]@{
  schema = 'runtime-separation-receipt.v1'; phase = '16'
  startedAt = $startedAt; endedAt = (Get-UtcNow)
  sourceSha = $srcSha; host = $hostName; openclawVersion = $ver
  commands = $commands.ToArray(); inputs = [ordered]@{}
  observations = $obs
  health = [ordered]@{ startupz = 0; readyz = 0 }
  result = $result
  rollback = [ordered]@{ artifact = $rbArtifact; deadlineUtc = ([DateTime]::UtcNow.AddDays(30).ToString('yyyy-MM-ddTHH:mm:ssZ')) }
}
$receiptSchema = Join-Path $PSScriptRoot '../../docs/spec/runtime-separation-receipt.v1.schema.json'
$json = (New-Object PSObject -Property $doc) | ConvertTo-Json -Depth 5 -Compress
$name = 'quarantine-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
  [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json'
Write-ReceiptAtomic -ReceiptJson $json -Path (Join-Path $ReceiptRoot $name) -SchemaPath $receiptSchema

if ($failed) {
  Write-Output ("FALLO: {0}" -f $failWhy)
  exit 1
}
exit 0
