# RuntimeSeparation.psm1 — contrato versionado de la separacion del runtime (Fase 16).
#
# Raices canonicas (diseno, "Disposicion de directorios"): el checkout dedicado
# es fuente, C:\Users\ehven\.openclaw es estado vivo del gateway y
# C:\Users\ehven\.openclaw-node es estado aislado del nodo. Los repos de
# workspace quedan excluidos del despliegue durante esta migracion.
#
# Todo Test-* devuelve booleano y no lanza por veredicto: solo lanza por fallo
# operativo (schema ilegible, disco). Write-* lanza ante recibo invalido o
# fallo de escritura: fallar cerrado. Sintaxis compatible con Windows
# PowerShell 5.1; la canonizacion de rutas es lexica con semantica Windows en
# cualquier plataforma para que el humo corra igual en 5.1 y 7.
$Script:CanonicalSourceRoot = 'C:\Users\ehven\src\goncloud-openclaw'
$Script:CanonicalRuntimeRoot = 'C:\Users\ehven\.openclaw'
$Script:CanonicalNodeRoot = 'C:\Users\ehven\.openclaw-node'
$Script:WorkspaceNames = @('workspace', 'workspace-ingenieria', 'workspace-operaciones')
# Mismo literal que x-secretKeyPattern / x-secretValuePattern del schema
# docs/spec/runtime-separation-receipt.v1.schema.json (paridad fijada por test).
$Script:SecretKeyPattern = '(?i)(password|passwd|secret|token|bearer|apikey|api[_-]?key|private[_-]?key|pairing|passphrase|credential|session[_-]?key|connection[_-]?string|authorization|cookie|transcript|memory[_-]?content|messages)'
$Script:SecretValuePattern = '(?im)(bearer\s+[A-Za-z0-9._~+/-]{16,}={0,2}|sk-[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[bpras]-[A-Za-z0-9-]+|-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----|(?-i:^[A-Z][A-Z0-9_]{2,}=[^\s]{4,}))'

function Get-RuntimeCanonicalRoots {
  return @{ Source = $Script:CanonicalSourceRoot; Runtime = $Script:CanonicalRuntimeRoot; Node = $Script:CanonicalNodeRoot }
}

function Get-CanonicalWindowsPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $p = $Path.Replace('/', '\')
  $prefix = $null
  if ($p -cmatch '^[A-Za-z]:\\') {
    $prefix = $p.Substring(0, 2).ToUpperInvariant() + '\'
    $rest = $p.Substring(3)
  } elseif ($p.StartsWith('\\')) {
    $m = [regex]::Match($p, '^\\\\[^\\]+\\[^\\]+\\?')
    if (-not $m.Success) { return $null }
    $prefix = $m.Value.TrimEnd('\') + '\'
    $rest = $p.Substring($m.Value.Length)
  } else {
    return $null
  }
  $segs = New-Object System.Collections.Generic.List[string]
  foreach ($s in $rest.Split('\')) {
    if ($s -eq '' -or $s -eq '.') { continue }
    if ($s -eq '..') {
      if ($segs.Count -eq 0) { return $null }
      [void]$segs.RemoveAt($segs.Count - 1)
      continue
    }
    [void]$segs.Add($s)
  }
  return ($prefix + ($segs -join '\'))
}

function Get-CanonicalNativePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ($Path -cmatch '^[A-Za-z]:[\\/]' -or $Path.StartsWith('\\')) {
    $c = Get-CanonicalWindowsPath -Path $Path
    if ($null -eq $c) { return $null }
    return @{ Canon = $c; Sep = '\'; Flavor = 'win' }
  }
  if ($Path.StartsWith('/')) {
    $segs = New-Object System.Collections.Generic.List[string]
    foreach ($s in $Path.Split('/')) {
      if ($s -eq '' -or $s -eq '.') { continue }
      if ($s -eq '..') {
        if ($segs.Count -eq 0) { return $null }
        [void]$segs.RemoveAt($segs.Count - 1)
        continue
      }
      [void]$segs.Add($s)
    }
    return @{ Canon = '/' + ($segs -join '/'); Sep = '/'; Flavor = 'posix' }
  }
  return $null
}

function Test-RootsIsolated {
  param([Parameter(Mandatory = $true)][string[]]$Roots)
  $canon = @()
  $flavor = $null
  foreach ($r in $Roots) {
    $c = Get-CanonicalNativePath -Path $r
    if ($null -eq $c) { return $false }
    if ($null -eq $flavor) { $flavor = $c.Flavor }
    elseif ($flavor -ne $c.Flavor) { return $false }
    $canon += $c
  }
  for ($i = 0; $i -lt $canon.Count; $i++) {
    for ($j = $i + 1; $j -lt $canon.Count; $j++) {
      $a = $canon[$i].Canon.ToLowerInvariant()
      $b = $canon[$j].Canon.ToLowerInvariant()
      $sep = $canon[$i].Sep
      if ($a -eq $b) { return $false }
      if ($b.StartsWith($a + $sep) -or $a.StartsWith($b + $sep)) { return $false }
    }
  }
  return $true
}

function Test-RuntimeLayout {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$RuntimeRoot,
    [Parameter(Mandatory = $true)][string]$NodeRoot
  )
  return (Test-RootsIsolated -Roots @($SourceRoot, $RuntimeRoot, $NodeRoot))
}

function Test-WorkspaceExcluded {
  param([Parameter(Mandatory = $true)][string]$Path)
  $c = Get-CanonicalWindowsPath -Path $Path
  if ($null -eq $c) { return $true }
  $low = $c.ToLowerInvariant()
  $rt = $Script:CanonicalRuntimeRoot.ToLowerInvariant()
  foreach ($w in $Script:WorkspaceNames) {
    if ($low -eq ($rt + '\' + $w) -or $low.StartsWith($rt + '\' + $w + '\')) { return $true }
  }
  return $false
}

function Test-JsonInteger {
  param($Value)
  if ($Value -is [bool]) { return $false }
  return (($Value -is [int]) -or ($Value -is [long]))
}

function Find-SecretShape {
  param($Node)
  if ($Node -is [string]) {
    if ($Node -match $Script:SecretValuePattern) { return $true }
    return $false
  }
  if ($Node -is [System.Collections.IDictionary]) {
    foreach ($k in $Node.Keys) {
      if ($k -match $Script:SecretKeyPattern) { return $true }
      if (Find-SecretShape -Node $Node[$k]) { return $true }
    }
    return $false
  }
  if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
    foreach ($v in $Node) {
      if (Find-SecretShape -Node $v) { return $true }
    }
    return $false
  }
  if ($null -ne $Node -and $Node -is [System.Management.Automation.PSCustomObject]) {
    foreach ($prop in $Node.PSObject.Properties) {
      if ($prop.Name -match $Script:SecretKeyPattern) { return $true }
      if (Find-SecretShape -Node $prop.Value) { return $true }
    }
  }
  return $false
}

function Get-RawJsonString {
  param(
    [Parameter(Mandatory = $true)][string]$Json,
    [Parameter(Mandatory = $true)][string]$Key
  )
  $m = [regex]::Match($Json, '"' + $Key + '"\s*:\s*"([^"]*)"')
  if (-not $m.Success) { return $null }
  return $m.Groups[1].Value
}

function Test-ReceiptObject {
  param(
    [Parameter(Mandatory = $true)][string]$ReceiptJson,
    [Parameter(Mandatory = $true)][string]$SchemaPath
  )
  if (-not (Test-Path -LiteralPath $SchemaPath)) { throw "schema ilegible: $SchemaPath" }
  $schema = Get-Content -Raw -LiteralPath $SchemaPath | ConvertFrom-Json
  try {
    $doc = $ReceiptJson | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $false
  }
  $want = @($schema.required)
  $got = @($doc.PSObject.Properties.Name)
  if ($want.Count -ne $got.Count) { return $false }
  foreach ($k in $want) {
    if ($got -notcontains $k) { return $false }
  }
  if (-not ($doc.schema -is [string]) -or $doc.schema -cne 'runtime-separation-receipt.v1') { return $false }
  if (-not ($doc.phase -is [string]) -or $doc.phase -cnotmatch '^[0-9]{1,3}(\.[0-9]{1,3})?$') { return $false }
  # ConvertFrom-Json convierte ISO8601 a [datetime] solo: la FORMA estricta
  # (con Z) se verifica contra el texto crudo y el instante contra el objeto.
  $utc = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$'
  foreach ($k in @('startedAt', 'endedAt')) {
    $raw = Get-RawJsonString -Json $ReceiptJson -Key $k
    if ($null -eq $raw -or $raw -cnotmatch $utc) { return $false }
    if (-not ($doc.$k -is [datetime])) { return $false }
    if (([datetime]$raw).ToUniversalTime() -ne ($doc.$k).ToUniversalTime()) { return $false }
  }
  if ($doc.endedAt.ToUniversalTime() -lt $doc.startedAt.ToUniversalTime()) { return $false }
  if (-not ($doc.sourceSha -is [string]) -or $doc.sourceSha -cnotmatch '^[0-9a-f]{40}$') { return $false }
  if (-not ($doc.host -is [string]) -or $doc.host.Length -eq 0 -or $doc.host.Length -gt 128) { return $false }
  if (-not ($doc.openclawVersion -is [string]) -or $doc.openclawVersion -cnotmatch '^\d{4}\.\d+\.\d+$') { return $false }
  $cmds = @($doc.commands)
  if ($cmds.Count -eq 0) { return $false }
  foreach ($c in $cmds) {
    $kn = @($c.PSObject.Properties.Name)
    if ($kn.Count -ne 2 -or $kn -notcontains 'name' -or $kn -notcontains 'exit') { return $false }
    if (-not ($c.name -is [string]) -or $c.name.Length -eq 0) { return $false }
    if (-not (Test-JsonInteger -Value $c.exit)) { return $false }
  }
  if (-not ($doc.inputs -is [PSCustomObject])) { return $false }
  foreach ($pr in @($doc.inputs.PSObject.Properties)) {
    $h = $pr.Value
    if (-not ($h -is [PSCustomObject])) { return $false }
    if ($h.algo -cne 'sha256') { return $false }
    if (-not ($h.sha256 -is [string]) -or $h.sha256 -cnotmatch '^[0-9a-f]{64}$') { return $false }
  }
  $obs = @($doc.observations)
  if ($obs.Count -gt 20) { return $false }
  foreach ($o in $obs) {
    if (-not ($o -is [string]) -or $o.Length -eq 0 -or $o.Length -gt 300) { return $false }
  }
  $hk = @($doc.health.PSObject.Properties.Name)
  if ($hk.Count -ne 2 -or $hk -notcontains 'startupz' -or $hk -notcontains 'readyz') { return $false }
  if (-not (Test-JsonInteger -Value $doc.health.startupz)) { return $false }
  if (-not (Test-JsonInteger -Value $doc.health.readyz)) { return $false }
  if (@('passed', 'failed', 'rolled_back') -notcontains $doc.result) { return $false }
  $rk = @($doc.rollback.PSObject.Properties.Name)
  if ($rk.Count -ne 2 -or $rk -notcontains 'artifact' -or $rk -notcontains 'deadlineUtc') { return $false }
  if (-not ($doc.rollback.artifact -is [string]) -or $doc.rollback.artifact.Length -eq 0) { return $false }
  $rawDl = Get-RawJsonString -Json $ReceiptJson -Key 'deadlineUtc'
  if ($null -eq $rawDl -or $rawDl -cnotmatch $utc) { return $false }
  if (-not ($doc.rollback.deadlineUtc -is [datetime])) { return $false }
  if (([datetime]$rawDl).ToUniversalTime() -ne ($doc.rollback.deadlineUtc).ToUniversalTime()) { return $false }
  if (Find-SecretShape -Node $doc) { return $false }
  return $true
}

function Write-ReceiptAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$ReceiptJson,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$SchemaPath
  )
  if (-not (Test-ReceiptObject -ReceiptJson $ReceiptJson -SchemaPath $SchemaPath)) {
    throw 'recibo invalido: no se escribe nada'
  }
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { throw "directorio destino inexistente: $dir" }
  $tmp = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
  try {
    [IO.File]::WriteAllText($tmp, $ReceiptJson, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    throw
  }
}

function ConvertTo-DeployRegex {
  param([Parameter(Mandatory = $true)][string]$Pattern)
  if ($Pattern.EndsWith('/')) {
    return ('^' + [regex]::Escape($Pattern))
  }
  if ($Pattern.Contains('*') -or $Pattern.Contains('?')) {
    $out = ''
    $i = 0
    while ($i -lt $Pattern.Length) {
      $c = $Pattern[$i]
      if ($c -eq '*') {
        if ((($i + 1) -lt $Pattern.Length) -and ($Pattern[$i + 1] -eq '*')) {
          if ((($i + 2) -lt $Pattern.Length) -and ($Pattern[$i + 2] -eq '/')) {
            $out += '(.*/)?'; $i += 3
          } else {
            $out += '.*'; $i += 2
          }
        } else {
          $out += '[^/]*'; $i += 1
        }
      } elseif ($c -eq '?') {
        $out += '[^/]'; $i += 1
      } else {
        $out += [regex]::Escape($c.ToString()); $i += 1
      }
    }
    return ('^' + $out + '$')
  }
  return ('^' + [regex]::Escape($Pattern) + '$')
}

function Test-DeployPathSafety {
  param([Parameter(Mandatory = $true)][string]$RelativePath)
  $p = $RelativePath.Replace('\', '/')
  if ($RelativePath -match '^[A-Za-z]:[\\/]') { return 'absoluta' }
  if ($p.StartsWith('/')) { return 'absoluta' }
  if ($p.Contains(':')) { return 'dos-puntos-stream' }
  if ($p -match '[\x00-\x1f\x7f]') { return 'control' }
  $segs = $p.Split('/')
  foreach ($s in $segs) {
    if ($s -eq '') { return 'segmento-vacio' }
    if ($s -eq '..') { return 'dotdot' }
    if ($s -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') { return "reservado:$s" }
    if ($s -match '[. ]$') { return "cola-punto-espacio:$s" }
  }
  return $null
}

function Test-DeployPathClassification {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$ManifestPath
  )
  if ($null -ne (Test-DeployPathSafety -RelativePath $RelativePath)) { return 'rejected' }
  if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "manifiesto ilegible: $ManifestPath" }
  $m = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
  $p = $RelativePath.Replace('\', '/')
  foreach ($e in $m.denied) {
    $rx = ConvertTo-DeployRegex -Pattern $e.pattern
    if ($p -match $rx) { return 'rejected' }
  }
  foreach ($e in $m.allowed) {
    if ($e.kind -eq 'file') {
      if ($p -eq $e.path) { return 'deployable' }
    } elseif ($e.kind -eq 'dir') {
      if ($p.ToLowerInvariant().StartsWith($e.path.ToLowerInvariant())) { return 'deployable' }
    } else {
      $rx = ConvertTo-DeployRegex -Pattern $e.path
      if ($p -match $rx) { return 'deployable' }
    }
  }
  return 'unclassified'
}

function Test-EffectiveHttpTimeout {
  param([Parameter(Mandatory = $true)][string]$Path)
  $vals = @()
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if ($line -match '^\s*\$httpTimeoutSec\s*=\s*(.+?)\s*(#.*)?$') {
      $vals += $Matches[1]
    }
  }
  if ($vals.Count -ne 1) { return $false }
  if ($vals[0] -cnotmatch '^\d+$') { return $false }
  return ([int]$vals[0] -ge 90)
}

function Test-HashEqual {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256
  )
  try {
    $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
  } catch {
    return $false
  }
  return ($h -ceq $ExpectedSha256.ToLowerInvariant())
}

Export-ModuleMember -Function Get-RuntimeCanonicalRoots, Test-RuntimeLayout, Test-WorkspaceExcluded, Test-ReceiptObject, Write-ReceiptAtomic, Test-DeployPathClassification, Test-EffectiveHttpTimeout, Test-HashEqual, Test-RootsIsolated
