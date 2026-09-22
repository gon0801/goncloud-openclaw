# Sync-OpenClawRuntime.ps1 — ciclo main: checkout fuente, capture por PR, ledger y deploy.
#
# Fases: mutex global, reconciliacion del checkout (main = origin/main, limpio,
# sin locales), refresh de PRs del ledger, escaneo vivo vs fuente, capturas
# (worktree temporal desde origin/main, rutas explicitas, scan, push de rama,
# gh pr create), deploy al mergear con hashes de acuerdo, recibo y journal.
# Sin cambios = solo lineas de log (sin recibo, ledger ni journal). Salidas:
# 0 ok (incluye protecciones atendidas), 1 fuente, 2 capture, 3 deploy, 4 busy.
# Nunca empuja main; nunca corre git dentro del runtime.
param(
  [Parameter(Mandatory = $true)][string]$SourceRoot,
  [Parameter(Mandatory = $true)][string]$RuntimeRoot,
  [Parameter(Mandatory = $true)][string]$ReceiptRoot,
  [string]$ManifestPath = '',
  [string]$LedgerPath = '',
  [string]$JournalPath = '',
  [string]$LogPath = '',
  [string]$DeployScriptPath = '',
  [string]$StagingRoot = '',
  [string]$HealthUrl = 'http://127.0.0.1:18789',
  [string]$MutexName = 'Global\OpenClawRuntimeSync',
  [string]$OpenClawVersion = '',
  [string]$SourceSha = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'RuntimeSeparation.psm1') -Force

$MAX_CAPTURE_KB = 512
$MAX_CAPTURE_FILES = 100
$CAPTURE_EXTS = @('.md')
$ZERO64 = '0' * 64

if ([string]::IsNullOrEmpty($ManifestPath)) { $ManifestPath = Join-Path $SourceRoot 'config/runtime-deploy.v1.json' }
if ([string]::IsNullOrEmpty($LedgerPath)) { $LedgerPath = Join-Path $RuntimeRoot '.ledger/skills-pr-ledger.json' }
if ([string]::IsNullOrEmpty($JournalPath)) { $JournalPath = Join-Path $RuntimeRoot '.ledger/sync.journal.jsonl' }
if ([string]::IsNullOrEmpty($LogPath)) { $LogPath = Join-Path $RuntimeRoot 'logs/sync-repos.log' }
if ([string]::IsNullOrEmpty($DeployScriptPath)) { $DeployScriptPath = Join-Path $PSScriptRoot 'Invoke-OpenClawDeploy.ps1' }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$RuntimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path

function Write-SyncLog([string]$Msg) {
  $dir = Split-Path -Parent $LogPath
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  Add-Content -LiteralPath $LogPath -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg)
}

$script:journalStarted = $false
$script:runId = [Guid]::NewGuid().ToString('N')
function Write-Journal([string]$Op, [string]$Detail) {
  $dir = Split-Path -Parent $JournalPath
  if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  if (-not $script:journalStarted) {
    Add-Content -LiteralPath $JournalPath -Value ('{"op":"cycle-start","run":"' + $script:runId + '"}')
    $script:journalStarted = $true
  }
  $d = $Detail.Replace('\', '\\').Replace('"', '\"')
  Add-Content -LiteralPath $JournalPath -Value ('{"op":"' + $Op + '","run":"' + $script:runId + '","detail":"' + $d + '"}')
}
function Write-JournalEnd {
  if ($script:journalStarted) {
    Add-Content -LiteralPath $JournalPath -Value ('{"op":"cycle-end","run":"' + $script:runId + '"}')
  }
}
function Get-PriorCrash {
  if (-not (Test-Path -LiteralPath $JournalPath)) { return $false }
  $txt = Get-Content -Raw -LiteralPath $JournalPath
  $starts = ([regex]::Matches($txt, '"op":"cycle-start"')).Count
  $ends = ([regex]::Matches($txt, '"op":"cycle-end"')).Count
  return ($starts -gt $ends)
}

function Get-UtcNow { return ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) }
function Get-FileSha([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$script:resolvedVersion = $OpenClawVersion
function Get-ResolvedVersion {
  if ([string]::IsNullOrEmpty($script:resolvedVersion)) {
    $v = (& openclaw --version 2>&1 | Out-String)
    $m = [regex]::Match($v, '(\d{4}\.\d+\.\d+)')
    if (-not $m.Success) { throw 'version openclaw irresoluble' }
    $script:resolvedVersion = $m.Groups[1].Value
  }
  return $script:resolvedVersion
}

$mutex = $null
$lockStream = $null
try {
  $isWin = ([Environment]::OSVersion.Platform -eq 'Win32NT')
  if ($isWin) {
    $mutex = New-Object Threading.Mutex($false, $MutexName)
    if (-not $mutex.WaitOne(0)) {
      Write-SyncLog 'main mutex ocupado, ciclo busy'
      exit 4
    }
  } else {
    $lockDir = Split-Path -Parent $LedgerPath
    if (-not (Test-Path -LiteralPath $lockDir)) { [void](New-Item -ItemType Directory -Path $lockDir -Force) }
    try {
      $lockStream = [IO.File]::Open((Join-Path $lockDir 'sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
      Write-SyncLog 'main lock ocupado, ciclo busy'
      exit 4
    }
  }

  if (Get-PriorCrash) {
    Write-SyncLog 'main reanudando ciclo previo trunco'
  }
  $startedAt = Get-UtcNow
  $commands = New-Object System.Collections.Generic.List[object]
  $observations = New-Object System.Collections.Generic.List[string]
  $receiptEffective = $false
  function Test-LiveNovel([string]$Rel) {
    $lp = Join-Path $RuntimeRoot ($Rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $lp -PathType Leaf)) { return $true }
    $blob = (& git -C $SourceRoot hash-object $lp 2>$null)
    if ([string]::IsNullOrEmpty($blob)) { return $true }
    $hist = (& git -C $SourceRoot rev-list --objects --all -- $Rel 2>$null)
    foreach ($line in $hist) {
      if ($line -match "^$blob(\s|$)") { return $false }
    }
    return $true
  }

  # --- reconciliacion del checkout ---
  # 5.1 lanza con stderr nativo aunque vaya a $null (CI12); Continue
  # temporal para que mande el exit, como en PS7.
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & git -C $SourceRoot fetch origin --prune 2>$null } finally { $ErrorActionPreference = $prevEAP }
  if ($LASTEXITCODE -ne 0) {
    Write-SyncLog 'main FALLO: fetch de fuente no responde'
    exit 1
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'fetch'; exit = 0 })
  $branch = (& git -C $SourceRoot rev-parse --abbrev-ref HEAD 2>&1)
  $dirty = (& git -C $SourceRoot status --porcelain 2>&1)
  if ($branch -ne 'main') {
    if ($dirty) {
      Write-SyncLog ("main FALLO: rama $branch sucia, sin tocar")
      exit 1
    }
    # EAP temporal (CI12): stderr nativo no lanza.
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $SourceRoot checkout --quiet main 2>$null } finally { $ErrorActionPreference = $prevEAP }
    if ($LASTEXITCODE -ne 0) {
      Write-SyncLog 'main FALLO: no pude volver a main'
      exit 1
    }
  }
  $dirty = (& git -C $SourceRoot status --porcelain 2>&1)
  if ($dirty) {
    Write-SyncLog 'main FALLO: fuente sucia, sin tocar'
    exit 1
  }
  $ahead = [int](& git -C $SourceRoot rev-list --count 'origin/main..HEAD' 2>&1)
  if ($ahead -gt 0) {
    Write-SyncLog 'main FALLO: commits locales en fuente (prohibidos), sin tocar'
    exit 1
  }
  $behind = [int](& git -C $SourceRoot rev-list --count 'HEAD..origin/main' 2>&1)
  if ($behind -gt 0) {
    & git -C $SourceRoot merge --quiet --ff-only origin/main 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-SyncLog 'main FALLO: avance no fast-forward'
      exit 1
    }
  }
  $headNow = (& git -C $SourceRoot rev-parse HEAD 2>&1)
  $mainNow = (& git -C $SourceRoot rev-parse origin/main 2>&1)
  if ($headNow -ne $mainNow) {
    Write-SyncLog 'main FALLO: HEAD distinto de origin/main tras reconciliar'
    exit 1
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'reconcile'; exit = 0 })
  & git -C $SourceRoot worktree list --porcelain 2>&1 | Out-Null
  & git -C $SourceRoot worktree prune 2>&1 | Out-Null

  # --- ledger (lectura; escritura solo si cambia) ---
  $ledger = $null
  $ledgerDirty = $false
  if (Test-Path -LiteralPath $LedgerPath) {
    try {
      $ledger = Get-Content -Raw -LiteralPath $LedgerPath | ConvertFrom-Json
    } catch {
      Write-SyncLog 'main FALLO: ledger ilegible'
      exit 2
    }
    if ($ledger.schema -cne 'skills-pr-ledger.v1') {
      Write-SyncLog 'main FALLO: ledger con schema ajeno'
      exit 2
    }
  } else {
    $ledger = [PSCustomObject]@{
      schema = 'skills-pr-ledger.v1'; updatedUtc = (Get-UtcNow)
      entries = [PSCustomObject]@{}; tombstones = [PSCustomObject]@{}
    }
  }
  function Save-Ledger {
    $ledger.updatedUtc = Get-UtcNow
    $dir = Split-Path -Parent $LedgerPath
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $json = $ledger | ConvertTo-Json -Depth 6 -Compress
    $tmp = $LedgerPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $LedgerPath -Force
    Write-Journal 'ledger' 'write'
  }
  function Get-Entry([string]$Rel) {
    $p = $ledger.entries.PSObject.Properties[$Rel]
    if ($null -eq $p) { return $null }
    return $p.Value
  }
  function Set-Entry([string]$Rel, $Value) {
    if ($null -eq $ledger.entries.PSObject.Properties[$Rel]) {
      $ledger.entries | Add-Member -NotePropertyName $Rel -NotePropertyValue $Value
    } else {
      $ledger.entries.PSObject.Properties[$Rel].Value = $Value
    }
    $script:ledgerDirtyRef = $true
  }
  $script:ledgerDirtyRef = $false
  function Set-Tombstone([string]$Rel, [string]$Reason, [int]$Pr) {
    $t = [PSCustomObject]@{ reason = $Reason; createdUtc = (Get-UtcNow); pr = $Pr }
    if ($null -eq $ledger.tombstones.PSObject.Properties[$Rel]) {
      $ledger.tombstones | Add-Member -NotePropertyName $Rel -NotePropertyValue $t
    } else {
      $ledger.tombstones.PSObject.Properties[$Rel].Value = $t
    }
    $script:ledgerDirtyRef = $true
  }
  function Clear-Tombstone([string]$Rel) {
    if ($null -ne $ledger.tombstones.PSObject.Properties[$Rel]) {
      $ledger.tombstones.PSObject.Properties.Remove($Rel)
      $script:ledgerDirtyRef = $true
    }
  }

  # --- refresh de PRs abiertos (solo entradas previas con numero) ---
  foreach ($prop in @($ledger.entries.PSObject.Properties)) {
    $rel = $prop.Name
    $e = $prop.Value
    if ($e.status -cne 'open' -or $e.pr -le 0) { continue }
    $ancestor = $false
    & git -C $SourceRoot merge-base --is-ancestor $e.commit origin/main 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ancestor = $true }
    if ($ancestor) {
      $e.status = 'merged'
      $script:ledgerDirtyRef = $true
      Write-Journal 'pr' ("merged $rel #$($e.pr)")
      continue
    }
    $viewRaw = (& gh pr view $e.pr --json state,mergedAt,headRefOid,headRefName 2>&1)
    if ($LASTEXITCODE -ne 0) {
      Write-SyncLog ("main FALLO: gh pr view $($e.pr) fallo")
      exit 2
    }
    $view = $null
    try { $view = ($viewRaw | Out-String) | ConvertFrom-Json } catch { $view = $null }
    if ($null -eq $view -or [string]::IsNullOrEmpty($view.state)) {
      [void]$observations.Add("pr $($e.pr) sin estado; se conserva open")
      continue
    }
    if ($view.state -ceq 'MERGED') {
      $e.status = 'merged'
      $script:ledgerDirtyRef = $true
      Write-Journal 'pr' ("merged $rel #$($e.pr)")
    } elseif ($view.state -ceq 'CLOSED') {
      $e.status = 'closed-unmerged'
      Set-Tombstone -Rel $rel -Reason ("pr $($e.pr) cerrado-sin-merge") -Pr $e.pr
      Write-SyncLog ("main CONFLICTO: $rel en PR $($e.pr) cerrado-sin-merge; protegido")
      Write-Journal 'pr' ("closed $rel #$($e.pr)")
    }
  }
  [void]$commands.Add([PSCustomObject]@{ name = 'pr-refresh'; exit = 0 })

  # Adopcion: entradas pr=0 con rama empujada buscan su PR (crash tras push).
  # Corre antes de decidir para que el ciclo vea numeros, no ceros.
  foreach ($prop in @($ledger.entries.PSObject.Properties)) {
    $rel = $prop.Name
    $e = $prop.Value
    if ($e.pr -ne 0) { continue }
    $listRaw = (& gh pr list --head $e.branch --json number,headRefName 2>&1)
    if ($LASTEXITCODE -ne 0) {
      Write-SyncLog 'main FALLO: gh pr list fallo'
      exit 2
    }
    $found = @()
    try { $found = @(($listRaw | Out-String) | ConvertFrom-Json) } catch { $found = @() }
    if ($found.Count -eq 0) { continue }
    $num = [int]$found[0].number
    $e.pr = $num
    $remoteHead = (& git -C $SourceRoot ls-remote origin $e.branch 2>$null)
    if ($remoteHead -match '^([0-9a-f]{40})\s') { $e.commit = $Matches[1] }
    $e.updatedUtc = Get-UtcNow
    $script:ledgerDirtyRef = $true
    Write-SyncLog ("main SKILLS_PR $num adoptado para " + (Protect-LogToken -Text $rel))
    Write-Journal 'adopt' ("pr=$num $rel")
  }

  # --- escaneo vivo vs fuente ---
  $skillsRoot = Join-Path $RuntimeRoot 'agents'
  $liveSkills = @{}
  if (Test-Path -LiteralPath $skillsRoot) {
    $files = @(Get-ChildItem -LiteralPath $skillsRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName.Replace('\', '/') -match '/workshop-skills/' })
    foreach ($f in $files) {
      if (($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $rel0 = $f.FullName.Substring($RuntimeRoot.Length).TrimStart('\', '/').Replace('\', '/')
        Write-SyncLog ("main ALERTA link vivo no capturable: " + (Protect-LogToken -Text $rel0))
        continue
      }
      $rel0 = $f.FullName.Substring($RuntimeRoot.Length).TrimStart('\', '/').Replace('\', '/')
      $liveSkills[$rel0] = Get-FileSha -Path $f.FullName
    }
  }
  $srcSkills = @{}
  $srcAgents = Join-Path $SourceRoot 'agents'
  if (Test-Path -LiteralPath $srcAgents) {
    $files = @(Get-ChildItem -LiteralPath $srcAgents -Recurse -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName.Replace('\', '/') -match '/workshop-skills/' })
    foreach ($f in $files) {
      $rel0 = $f.FullName.Substring($SourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
      $srcSkills[$rel0] = Get-FileSha -Path $f.FullName
    }
  }

  # No-capturables: trackeados fuera de skills que difieren.
  $tracked = @(git -C $SourceRoot ls-files -z 2>$null | Out-String)
  foreach ($tp in ($tracked -split "`0")) {
    if ([string]::IsNullOrEmpty($tp)) { continue }
    if ($tp -match '/workshop-skills/') { continue }
    if ($tp -notmatch '^agents/') { continue }
    $liveP = Join-Path $RuntimeRoot ($tp.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $srcP = Join-Path $SourceRoot ($tp.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if ((Test-Path -LiteralPath $liveP -PathType Leaf) -and (Test-Path -LiteralPath $srcP -PathType Leaf)) {
      if ((Get-FileSha -Path $liveP) -cne (Get-FileSha -Path $srcP)) {
        Write-SyncLog ("main ALERTA ruta-no-capturable difiere, se preserva: " + (Protect-LogToken -Text $tp))
      }
    }
  }

  # Centinelas: config y watchdog vivos.
  if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'openclaw.json') -PathType Leaf)) {
    Set-Tombstone -Rel 'openclaw.json' -Reason 'config viva ausente' -Pr 0
    Write-SyncLog 'main CONFLICTO: openclaw.json vivo ausente; protegido hasta decision del dueno'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot 'gateway-watchdog.ps1') -PathType Leaf)) {
    Set-Tombstone -Rel 'gateway-watchdog.ps1' -Reason 'watchdog vivo ausente' -Pr 0
    Write-SyncLog 'main CONFLICTO: gateway-watchdog.ps1 vivo ausente; protegido hasta decision del dueno'
  }

  # --- decisiones por ruta ---
  $toCreate = New-Object System.Collections.Generic.List[object]
  $toUpdate = New-Object System.Collections.Generic.List[object]
  $toDeploy = New-Object System.Collections.Generic.List[string]
  $allRels = New-Object System.Collections.Generic.List[string]
  foreach ($k in $liveSkills.Keys) { [void]$allRels.Add($k) }
  foreach ($k in $srcSkills.Keys) { if (-not $liveSkills.ContainsKey($k)) { [void]$allRels.Add($k) } }
  foreach ($prop in $ledger.entries.PSObject.Properties) {
    if (-not $liveSkills.ContainsKey($prop.Name) -and -not $srcSkills.ContainsKey($prop.Name)) {
      [void]$allRels.Add($prop.Name)
    }
  }
  $sorted = $allRels | Sort-Object -Unique
  foreach ($rel in $sorted) {
    $e = Get-Entry -Rel $rel
    $liveH = $null
    if ($liveSkills.ContainsKey($rel)) { $liveH = $liveSkills[$rel] }
    $srcH = $null
    if ($srcSkills.ContainsKey($rel)) { $srcH = $srcSkills[$rel] }
    $liveCmp = $ZERO64
    if ($null -ne $liveH) { $liveCmp = $liveH }
    $deletedLive = ($null -eq $liveH -and $null -ne $srcH)
    if ($deletedLive) {
      if ($null -ne $e -and $e.status -ceq 'open') { continue }
      if ($null -ne $e -and $e.status -ceq 'merged' -and $e.capturedHash -ceq $ZERO64) {
        [void]$toDeploy.Add($rel)
        continue
      }
      if ($null -ne $e -and ($e.status -ceq 'merged' -or $e.status -ceq 'deployed') -and $e.capturedHash -cne $srcH) {
        $tb0 = $ledger.tombstones.PSObject.Properties[$rel]
        if ($null -eq $tb0) {
          Set-Tombstone -Rel $rel -Reason 'borrado vivo con fuente avanzada; decide el dueno' -Pr $e.pr
        }
        Write-SyncLog ("main ALERTA " + (Protect-LogToken -Text $rel) + " borrado en vivo pero fuente avanzo; sin PR")
        continue
      }
      $tb = $ledger.tombstones.PSObject.Properties[$rel]
      if ($null -ne $tb) { continue }
      [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = 'delete' })
      continue
    }
    if ($null -eq $e) {
      if ($liveH -cne $srcH) {
        if (-not (Test-LiveNovel -Rel $rel)) { continue }
        $kind = 'add'
        if ($null -ne $srcH) { $kind = 'modify' }
        [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = $kind })
      }
      continue
    }
    if ($e.status -ceq 'open') {
      if ($liveCmp -ceq $e.liveHash) { continue }
      if ($null -ne $liveH -and -not (Test-LiveNovel -Rel $rel)) { continue }
      $remote = (& git -C $SourceRoot ls-remote origin $e.branch 2>$null)
      if (-not [string]::IsNullOrEmpty($remote)) {
        [void]$toUpdate.Add([PSCustomObject]@{ Rel = $rel; Entry = $e })
      } elseif ($null -eq $liveH -and $null -eq $srcH) {
        continue
      } elseif ($null -eq $liveH) {
        [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = 'delete' })
      } else {
        [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = 'successor'; Prev = $e.pr })
      }
      continue
    }
    if ($e.status -ceq 'merged') {
      if ($liveCmp -ceq $e.capturedHash) {
        [void]$toDeploy.Add($rel)
      } elseif ($null -eq $liveH -and $null -eq $srcH) {
        [void]$toDeploy.Add($rel)
      } elseif ($null -eq $liveH) {
        [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = 'delete' })
      } else {
        if (-not (Test-LiveNovel -Rel $rel)) { continue }
        [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = 'successor'; Prev = $e.pr })
      }
      continue
    }
    if ($e.status -ceq 'closed-unmerged') {
      Set-Tombstone -Rel $rel -Reason ("pr $($e.pr) cerrado-sin-merge") -Pr $e.pr
      Write-SyncLog ("main CONFLICTO: $rel protegido, PR $($e.pr) cerrado-sin-merge")
      continue
    }
    if ($e.status -ceq 'deployed') {
      if ($liveCmp -cne $e.capturedHash) {
        if ($null -eq $liveH -and $null -eq $srcH) {
          continue
        } elseif ($null -eq $liveH) {
          [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = 'delete' })
        } elseif (Test-LiveNovel -Rel $rel) {
          [void]$toCreate.Add([PSCustomObject]@{ Rel = $rel; Kind = 'successor'; Prev = $e.pr })
        }
      }
      continue
    }
  }

  # Renombres: alta viva + baja fuente del mismo agente viajan en una rama
  # (el agrupo por agente los junta; el scan valida cada ruta por separado).

  function Invoke-CaptureBranch {
    param($Items, [string]$Mode, [int]$PrevPr)
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $agents = @($Items | ForEach-Object {
        if ($_.Rel -match '^agents/([^/]+)/agent/workshop-skills/') { $Matches[1] }
      } | Sort-Object -Unique)
    $who = 'multi'
    if ($agents.Count -eq 1) { $who = $agents[0] }
    $branch = "auto/skills/$stamp-$who"
    if ($Mode -ceq 'update') { $branch = $Items[0].Branch }
    & git -C $SourceRoot worktree prune 2>&1 | Out-Null
    if ($Mode -cne 'update') {
      $base = $branch
      $n = 1
      while ($true) {
        $local = (& git -C $SourceRoot branch --list $branch 2>$null)
        $rem = (& git -C $SourceRoot ls-remote origin $branch 2>$null)
        if ([string]::IsNullOrEmpty($local) -and [string]::IsNullOrEmpty($rem)) { break }
        if (-not [string]::IsNullOrEmpty($local) -and [string]::IsNullOrEmpty($rem)) {
          $abandon = "$branch-abandonado-$stamp"
          & git -C $SourceRoot branch -m $branch $abandon 2>&1 | Out-Null
          Write-SyncLog ("main rama local huerfana apartada: " + (Protect-LogToken -Text $abandon))
          break
        }
        $n++
        if ($n -gt 60) { return @{ Ok = $false; Why = 'sin rama libre' } }
        $branch = "$base-$n"
      }
    }
    $wt = Join-Path ([IO.Path]::GetTempPath()) ('capture-' + [Guid]::NewGuid().ToString('N'))
    try {
      # EAP temporal en este bloque (CI12): stderr nativo no lanza.
      $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try {
      if ($Mode -ceq 'update') {
        & git -C $SourceRoot fetch origin $branch 2>$null
        $hasLocal = (& git -C $SourceRoot branch --list $branch 2>$null)
        if ([string]::IsNullOrEmpty($hasLocal)) {
          & git -C $SourceRoot branch $branch "origin/$branch" 2>$null
          if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Why = 'rama-update irrecuperable' } }
        }
        & git -C $SourceRoot worktree add $wt $branch 2>$null
      } else {
        & git -C $SourceRoot worktree add $wt -b $branch origin/main 2>$null
      }
      } finally { $ErrorActionPreference = $prevEAP }
      if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Why = 'worktree add fallo' } }
      $staged = New-Object System.Collections.Generic.List[string]
      foreach ($it in $Items) {
        $rel = $it.Rel
        if ($rel -notmatch '^agents/[^/]+/agent/workshop-skills/.+$') {
          return @{ Ok = $false; Why = "ruta fuera de allowlist: $rel" }
        }
        $dst = Join-Path $wt ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ($it.Kind -ceq 'delete') {
          if (Test-Path -LiteralPath $dst) {
            & git -C $wt rm --quiet -- $rel 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Why = "git rm fallo: $rel" } }
            [void]$staged.Add($rel)
          }
        } else {
          $src = Join-Path $RuntimeRoot ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
          $dd = Split-Path -Parent $dst
          if (-not (Test-Path -LiteralPath $dd)) { [void](New-Item -ItemType Directory -Path $dd -Force) }
          Copy-Item -LiteralPath $src -Destination $dst -Force
          & git -C $wt add -- $rel 2>&1 | Out-Null
          if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Why = "stage fallo: $rel" } }
          [void]$staged.Add($rel)
        }
      }
      if ($staged.Count -eq 0) { return @{ Ok = $false; Why = 'nada staged' } }
      if ($staged.Count -gt $MAX_CAPTURE_FILES) { return @{ Ok = $false; Why = 'excede conteo' } }
      $hashes = @{}
      foreach ($s in $staged) {
        $ext = [IO.Path]::GetExtension($s)
        if ($CAPTURE_EXTS -notcontains $ext) {
          Write-SyncLog ("main ALERTA extension no capturable: " + (Protect-LogToken -Text $s))
          return @{ Ok = $false; Why = "extension: $s" }
        }
        $wf = Join-Path $wt ($s.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if (Test-Path -LiteralPath $wf -PathType Leaf) {
          if ((Get-Item -LiteralPath $wf).Length -gt ($MAX_CAPTURE_KB * 1KB)) {
            Write-SyncLog ("main ALERTA excede tamano: " + (Protect-LogToken -Text $s))
            return @{ Ok = $false; Why = "tamano: $s" }
          }
          $bytes = [IO.File]::ReadAllBytes($wf)
          foreach ($b in $bytes) {
            if ($b -eq 0 -or ($b -lt 32 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13)) {
              Write-SyncLog ("main ALERTA binario o control: " + (Protect-LogToken -Text $s))
              return @{ Ok = $false; Why = "contenido: $s" }
            }
          }
          if ($s -match '^agents/([^/]+)/agent/workshop-skills/') {
            if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot (Join-Path 'agents' $Matches[1])))) {
              Write-SyncLog ("main ALERTA agente inesperado: " + (Protect-LogToken -Text $s))
              return @{ Ok = $false; Why = "agente: $s" }
            }
          }
          $hashes[$s] = Get-FileSha -Path $wf
        } else {
          $hashes[$s] = $ZERO64
        }
      }
      $title = "capture(skills): $who $($staged.Count) ruta(s)"
      $body = "Capture automatica de skills vivas."
      if ($PrevPr -gt 0) { $body = "Successor of #$PrevPr. $body" }
      & git -C $wt -c user.name=openclaw-auto -c user.email=ehventasmx@gmail.com commit --quiet -m $title 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Why = 'commit fallo' } }
      $commit = (& git -C $wt rev-parse HEAD 2>&1)
      Push-Location -LiteralPath $wt
      try {
        git push --quiet origin $branch 2>&1 | Out-Null
      } finally {
        Pop-Location
      }
      if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Why = 'push fallo' } }
      if ($Mode -ceq 'update') {
        return @{ Ok = $true; Branch = $branch; Commit = $commit; Hashes = $hashes; Pr = $Items[0].Pr }
      }
      $prRaw = (& gh pr create --title $title --body $body --head $branch --base main --json number,url 2>&1)
      if ($LASTEXITCODE -ne 0) { return @{ Ok = $false; Why = 'gh pr create fallo'; Pushed = $true; Branch = $branch; Commit = $commit; Hashes = $hashes } }
      $prNum = 0
      try { $prNum = ([int]((($prRaw | Out-String) | ConvertFrom-Json).number)) } catch { $prNum = 0 }
      if ($prNum -le 0) { return @{ Ok = $false; Why = 'gh sin numero'; Pushed = $true; Branch = $branch; Commit = $commit; Hashes = $hashes } }
      return @{ Ok = $true; Branch = $branch; Commit = $commit; Hashes = $hashes; Pr = $prNum }
    } finally {
      if (Test-Path -LiteralPath $wt) {
        Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
      }
      & git -C $SourceRoot worktree prune 2>$null | Out-Null
    }
  }

  # Capturas nuevas (agrupadas por corrida; una rama por grupo de agente).
  if ($toCreate.Count -gt 0) {
    $groups = @{}
    foreach ($c in $toCreate) {
      $a = 'multi'
      if ($c.Rel -match '^agents/([^/]+)/agent/workshop-skills/') { $a = $Matches[1] }
      if (-not $groups.ContainsKey($a)) { $groups[$a] = New-Object System.Collections.Generic.List[object] }
      [void]$groups[$a].Add($c)
    }
    foreach ($a in ($groups.Keys | Sort-Object)) {
      $items = $groups[$a].ToArray()
      $prev = 0
      foreach ($it in $items) {
        if ($it.PSObject.Properties['Prev'] -and $it.Prev -gt $prev) { $prev = $it.Prev }
      }
      $r = Invoke-CaptureBranch -Items $items -Mode 'create' -PrevPr $prev
      if (-not $r.Ok) {
        if ($r.Pushed) {
          foreach ($it in $items) {
            $lh = $ZERO64
            if ($liveSkills.ContainsKey($it.Rel)) { $lh = $liveSkills[$it.Rel] }
            $entry = [PSCustomObject]@{
              liveHash = $lh; capturedHash = $r.Hashes[$it.Rel]; branch = $r.Branch
              commit = $r.Commit; pr = 0; status = 'open'; previousPr = $prev; updatedUtc = (Get-UtcNow)
            }
            Set-Entry -Rel $it.Rel -Value $entry
          }
          Save-Ledger
        }
        Write-SyncLog ("main FALLO: capture: " + $r.Why)
        exit 2
      }
      foreach ($it in $items) {
        $lh = $ZERO64
        if ($liveSkills.ContainsKey($it.Rel)) { $lh = $liveSkills[$it.Rel] }
        $oldPrev = $prev
        $old = Get-Entry -Rel $it.Rel
        if ($null -ne $old -and $old.pr -gt 0 -and $old.pr -ne $r.Pr) { $oldPrev = $old.pr }
        $entry = [PSCustomObject]@{
          liveHash = $lh; capturedHash = $r.Hashes[$it.Rel]; branch = $r.Branch
          commit = $r.Commit; pr = $r.Pr; status = 'open'; previousPr = $oldPrev; updatedUtc = (Get-UtcNow)
        }
        Set-Entry -Rel $it.Rel -Value $entry
        if ($it.Kind -ceq 'delete') {
          Set-Tombstone -Rel $it.Rel -Reason ("deleted-live pending pr $($r.Pr)") -Pr $r.Pr
        }
      }
      $paths = ($items | ForEach-Object { Protect-LogToken -Text $_.Rel }) -join ' '
      Write-SyncLog ("main SKILLS_PR $($r.Pr) $a " + $paths)
      Write-Journal 'capture' ("pr=$($r.Pr) n=$($items.Count)")
      [void]$commands.Add([PSCustomObject]@{ name = 'capture'; exit = 0 })
      $receiptEffective = $true
    }
  }

  # Updates a ramas abiertas.
  foreach ($u in $toUpdate) {
    $rel = $u.Rel
    $e = $u.Entry
    $kind = 'modify'
    if (-not $srcSkills.ContainsKey($rel)) { $kind = 'add' }
    if (-not $liveSkills.ContainsKey($rel)) { $kind = 'delete' }
    $items = @([PSCustomObject]@{ Rel = $rel; Kind = $kind; Branch = $e.branch; Pr = $e.pr })
    $r = Invoke-CaptureBranch -Items $items -Mode 'update' -PrevPr 0
    if (-not $r.Ok) {
      Write-SyncLog ("main FALLO: update $($e.pr): " + $r.Why)
      exit 2
    }
    $e.liveHash = $ZERO64
    if ($liveSkills.ContainsKey($rel)) { $e.liveHash = $liveSkills[$rel] }
    $e.capturedHash = $r.Hashes[$rel]
    $e.commit = $r.Commit
    $e.updatedUtc = Get-UtcNow
    $script:ledgerDirtyRef = $true
    Write-SyncLog ("main SKILLS_PR_UPDATE $($e.pr) " + $e.liveHash.Substring(0, 8))
    Write-Journal 'update' ("pr=$($e.pr) $rel")
    [void]$commands.Add([PSCustomObject]@{ name = 'capture-update'; exit = 0 })
    $receiptEffective = $true
  }

  if ($script:ledgerDirtyRef) {
    Save-Ledger
  }

  # --- deploy al mergear con acuerdo ---
  if ($toDeploy.Count -gt 0) {
    $excl = New-Object System.Collections.Generic.List[string]
    foreach ($tp in @($ledger.tombstones.PSObject.Properties)) { [void]$excl.Add($tp.Name) }
    foreach ($prop in @($ledger.entries.PSObject.Properties)) {
      if ($prop.Value.status -ceq 'closed-unmerged' -and $excl -notcontains $prop.Name) {
        [void]$excl.Add($prop.Name)
      }
    }
    $stg = $StagingRoot
    if ([string]::IsNullOrEmpty($stg)) {
      $stg = Join-Path ([IO.Path]::GetTempPath()) ('sync-staging-' + [Guid]::NewGuid().ToString('N'))
    }
    try {
      $ver = Get-ResolvedVersion
    } catch {
      Write-SyncLog 'main FALLO: version openclaw irresoluble para deploy'
      exit 3
    }
    & $DeployScriptPath -SourceRoot $SourceRoot -RuntimeRoot $RuntimeRoot -StagingRoot $stg `
      -ReceiptRoot $ReceiptRoot -ManifestPath $ManifestPath -HealthUrl $HealthUrl `
      -OpenClawVersion $ver -ExcludePaths $excl.ToArray() -Apply 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-SyncLog ("main FALLO: deploy exit $LASTEXITCODE")
      [void]$commands.Add([PSCustomObject]@{ name = 'deploy'; exit = $LASTEXITCODE })
      exit 3
    }
    [void]$commands.Add([PSCustomObject]@{ name = 'deploy'; exit = 0 })
    foreach ($rel in ($toDeploy | Sort-Object)) {
      $e = Get-Entry -Rel $rel
      $e.status = 'deployed'
      $e.updatedUtc = Get-UtcNow
      Clear-Tombstone -Rel $rel
      Write-SyncLog ("main SKILLS_DEPLOYED $headNow " + (Protect-LogToken -Text $rel))
    }
    $script:ledgerDirtyRef = $true
    Save-Ledger
    $receiptEffective = $true
    Write-Journal 'deploy' ("n=$($toDeploy.Count)")
  }

  # --- recibo solo si hubo capture, update o deploy ---
  if ($receiptEffective) {
    try {
      $ver = Get-ResolvedVersion
    } catch {
      Write-SyncLog 'main FALLO: version openclaw irresoluble para recibo'
      exit 3
    }
    $h = @{ startupz = 0; readyz = 0 }
    try {
      $rs = Invoke-WebRequest -Uri ($HealthUrl + '/startupz') -TimeoutSec 5 -UseBasicParsing
      $h['startupz'] = [int]$rs.StatusCode
    } catch { $h['startupz'] = 0 }
    try {
      $rr = Invoke-WebRequest -Uri ($HealthUrl + '/readyz') -TimeoutSec 5 -UseBasicParsing
      $h['readyz'] = [int]$rr.StatusCode
    } catch { $h['readyz'] = 0 }
    $obs = $observations.ToArray()
    if ($obs.Count -eq 0) { $obs = @('ciclo efectivo') }
    if ($obs.Count -gt 20) { $obs = $obs[0..19] }
    $sha = $SourceSha
    if ([string]::IsNullOrEmpty($sha)) { $sha = $headNow }
    $hostName = $env:COMPUTERNAME
    if ([string]::IsNullOrEmpty($hostName)) { $hostName = (& hostname) }
    if ($hostName.Length -gt 128) { $hostName = $hostName.Substring(0, 128) }
    $doc = [ordered]@{
      schema = 'runtime-separation-receipt.v1'; phase = '16'
      startedAt = $startedAt; endedAt = (Get-UtcNow)
      sourceSha = $sha; host = $hostName; openclawVersion = $ver
      commands = $commands.ToArray(); inputs = @{}; observations = $obs
      health = [ordered]@{ startupz = $h['startupz']; readyz = $h['readyz'] }
      result = 'passed'
      rollback = [ordered]@{ artifact = $LedgerPath; deadlineUtc = ([DateTime]::UtcNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ssZ')) }
    }
    $receiptSchema = Join-Path $PSScriptRoot '../../docs/spec/runtime-separation-receipt.v1.schema.json'
    $json = (New-Object PSObject -Property $doc) | ConvertTo-Json -Depth 5 -Compress
    $name = 'sync-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
      [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json'
    if (-not (Test-Path -LiteralPath $ReceiptRoot)) {
      [void](New-Item -ItemType Directory -Path $ReceiptRoot -Force)
    }
    Write-ReceiptAtomic -ReceiptJson $json -Path (Join-Path $ReceiptRoot $name) -SchemaPath $receiptSchema
  } else {
    Write-SyncLog 'main ciclo sin cambios'
  }
  Write-JournalEnd
  exit 0
} finally {
  if ($null -ne $mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
  if ($null -ne $lockStream) { $lockStream.Close(); $lockStream.Dispose() }
}
