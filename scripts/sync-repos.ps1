# U1-OBSOLETO: este sync hacía `git add -A` dentro del estado vivo
# (C:\Users\ehven\.openclaw), prohibido por el contrato "Propiedad del runtime
# Windows" (docs/spec/00-project-spec.md). Se conserva por historia; el camino
# activo es scripts/sync-seguro/ (desactivado por defecto, flag explícito).
# No volver a programar ni invocar desde código nuevo.
# sync-repos.ps1 - sincroniza los 4 repos goncloud con GitHub (pull + commit local + push)
$log = 'C:\Users\ehven\.openclaw\logs\sync-repos.log'
$repos = @(
  'C:\Users\ehven\.openclaw',
  'C:\Users\ehven\.openclaw\workspace',
  'C:\Users\ehven\.openclaw\workspace-ingenieria',
  'C:\Users\ehven\.openclaw\workspace-operaciones'
)
function Log($msg) { Add-Content $log ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) }

# >>> skills-cambiadas
# Lista lo estagiado bajo agents/*/agent/workshop-skills/. Vive aqui (no en otro
# archivo) porque GoncloudRepoSync no garantiza el cwd: un dot-source a un .ps1
# que no llego tumbaria los 4 repos.
function Get-OpenclawSkillsCambiadasStaged {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)
  $staged = @(git -C $RepoRoot diff --cached --name-only 2>$null)
  $byAgent = @{}
  foreach ($g in $staged) {
    $norm = ($g -replace '\\', '/')
    if ($norm -match '^agents/([^/]+)/agent/workshop-skills/(.+)$') {
      $agent = $Matches[1]
      $rel = $Matches[2]
      if (-not $byAgent.ContainsKey($agent)) {
        $byAgent[$agent] = New-Object System.Collections.Generic.List[string]
      }
      [void]$byAgent[$agent].Add($rel)
    }
  }
  return $byAgent
}

function Write-OpenclawSkillsLog {
  param(
    [Parameter(Mandatory = $true)]$Snap,
    [Parameter(Mandatory = $true)][string]$LogPath
  )
  if (-not $Snap -or $Snap.Count -eq 0) { return }
  foreach ($agent in ($Snap.Keys | Sort-Object)) {
    $files = @($Snap[$agent] | Sort-Object)
    $n = $files.Count
    $list = $files -join ','
    $line = "{0} .openclaw SKILLS {1} {2} archivo(s): {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $agent, $n, $list
    Add-Content -LiteralPath $LogPath -Value $line
  }
}

# Entrada unica para el test: lista lo estagiado y escribe el log.
function Write-OpenclawSkillsCambiadas {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$LogPath
  )
  $snap = Get-OpenclawSkillsCambiadasStaged -RepoRoot $RepoRoot
  Write-OpenclawSkillsLog -Snap $snap -LogPath $LogPath
}
# <<< skills-cambiadas

foreach ($r in $repos) {
  if (-not (Test-Path (Join-Path $r '.git'))) { Log "SKIP $r (sin .git)"; continue }
  Set-Location $r
  $name = Split-Path $r -Leaf
  $branch = git branch --show-current
  $pre = git rev-parse HEAD

  # 1. Commitear cambios locales (de agentes o del gateway)
  # `git add -A` es atomico: un solo path invalido (p.ej. un repo git anidado sin commits)
  # aborta todo el add y deja el arbol sucio, con lo que el pull siguiente se niega
  # (2026-09-11, workspace-scout/). Si falla, se loguea el motivo y se cae a `add -u`
  # (solo tracked) para que al menos el ciclo avance.
  $addOut = git add -A 2>&1
  if ($LASTEXITCODE -ne 0) {
    $why = (@($addOut) | ForEach-Object { "$_" } | Where-Object { $_ -match 'error|fatal' } | Select-Object -Last 2) -join ' | '
    Log "$name add -A FALLO (cayendo a add -u): $why"
    git add -u 2>&1 | Out-Null
  }

  # 1b. GUARDIA DE TAMANO. `add -A` se lleva lo que encuentre, y lo que encuentre no
  # siempre es codigo. Medido el 2026-09-18: el snapshot de las 03:10 subio a main
  # lego.exe (66 MB) y lego.zip (21 MB), que el gateway habia dejado en tls/bin. Tumbo
  # el CI tres corridas seguidas -- dos de ellas de PRs ajenos que solo heredaron el
  # rojo -- y bloqueo el cierre de las Fases 6 y 7, que exigen la rama por defecto en
  # verde. Este sync no pasa por los candados del repo, asi que nada mas lo frenaba.
  #
  # Se desestagea, NO se borra: el archivo se queda en el disco del gateway, que es
  # donde hace falta (lego renueva los certificados). Y se loguea cada ciclo a
  # proposito: el vigia lee este log, y un archivo grande que aparece y no se sube es
  # exactamente lo que una persona tiene que ver.
  $MAX_MB = 5
  foreach ($g in @(git diff --cached --name-only 2>$null)) {
    $f = Join-Path $r $g
    if ((Test-Path -LiteralPath $f -PathType Leaf) -and ((Get-Item -LiteralPath $f).Length -gt ($MAX_MB * 1MB))) {
      git restore --staged -- "$g" 2>&1 | Out-Null
      $mb = [math]::Round((Get-Item -LiteralPath $f).Length / 1MB, 1)
      Log "$name GRANDE no se sube: $g ($mb MB; limite $MAX_MB MB)"
    }
  }

  # Lo que decide si hay algo que commitear es el INDICE, no el arbol: tras la guardia
  # de tamano el archivo grande sigue en `status --porcelain` (queda sin rastrear), y
  # mirar el arbol hacia intentar un commit con el indice vacio. Git lo rechaza y el log
  # decia FALLO aunque la guardia hubiera hecho exactamente su trabajo.
  # `git diff --cached --quiet` devuelve 0 con el indice limpio y 1 cuando hay algo
  # estagiado. Cualquier OTRO codigo (128 por indice corrupto o por un lock) es un fallo
  # de git, no "hay trabajo": se distingue, porque tratarlo como trabajo intenta un
  # commit condenado y confunde el diagnostico. Hallazgo de kimi, 2026-09-18.
  git diff --cached --quiet
  $rc_diff = $LASTEXITCODE
  $hay_estagiado = ($rc_diff -eq 1)
  if ($rc_diff -gt 1) {
    Log "$name no pude leer el indice (git diff --cached salio $rc_diff): no se intenta commit"
  }
  # Si el arbol trae cambios pero el indice quedo vacio, algo se los comio: el fallback a
  # `add -u` con solo archivos nuevos, o la guardia de tamano. Antes esto se veia como un
  # FALLO de commit -- ruido, pero VISIBLE. Con la guardia, el commit se salta y sin esta
  # linea el log no diria nada nunca: un repo que dejo de commitear en silencio. Hallazgo
  # de kimi: el arreglo no puede cambiar ruido por silencio.
  if (-not $hay_estagiado -and $rc_diff -le 1) {
    $sucio = git status --porcelain
    if ($sucio) { Log "$name hay cambios en el arbol y NADA estagiado: no se commitea nada este ciclo" }
  }
  if ($hay_estagiado) {
    # Listar skills ANTES del commit (despues el indice queda vacio). Escribir el
    # log solo si el commit sale bien. try/catch: un fallo no tumba el sync.
    $skillsSnap = $null
    if ($name -eq '.openclaw') {
      try {
        $skillsSnap = Get-OpenclawSkillsCambiadasStaged -RepoRoot $r
      } catch {
        Log (".openclaw SKILLS error: {0}" -f $_.Exception.Message)
      }
    }
    $commitOut = git -c user.name="openclaw-auto" -c user.email="ehventasmx@gmail.com" commit -m "auto: snapshot $name $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 2>&1
    if ($LASTEXITCODE -eq 0) {
      Log "$name commit local auto"
      if ($name -eq '.openclaw' -and $null -ne $skillsSnap) {
        try {
          Write-OpenclawSkillsLog -Snap $skillsSnap -LogPath $log
        } catch {
          Log (".openclaw SKILLS error: {0}" -f $_.Exception.Message)
        }
      }
    } else {
      # Un commit que falla en silencio deja el arbol sucio y el pull siguiente se niega ("CONFLICTO").
      $why = (@($commitOut) | ForEach-Object { "$_" } | Where-Object { $_ -match 'error|fatal|hook|Failed|identity' } | Select-Object -Last 2) -join ' | '
      Log "$name commit local FALLO: $why"
    }
  }

  # 2. Bajar cambios de GitHub (ediciones desde la Mac)
  git fetch origin 2>&1 | Out-Null
  # El rebase reescribe los commits locales y exige identidad: sin -c falla con
  # "Committer identity unknown" en cuanto hay commits de los dos lados (paso 2026-09-10/11,
  # y el log solo decia CONFLICTO). Misma identidad que el commit auto, y se guarda el motivo.
  $pullOut = git -c user.name="openclaw-auto" -c user.email="ehventasmx@gmail.com" pull --rebase origin $branch 2>&1
  if ($LASTEXITCODE -ne 0) {
    git rebase --abort 2>$null
    $why = (@($pullOut) | ForEach-Object { "$_" } | Where-Object { $_ -match 'error|fatal|CONFLICT|identity|Please tell me|unstaged|uncommitted|cannot pull' } | Select-Object -Last 2) -join ' | '
    Log "$name CONFLICTO en pull - se deja como estaba, revisar a mano: $why"
  } else {
    $post = git rev-parse HEAD
    if ($post -ne $pre) {
      Log "$name pull aplico cambios ($pre -> $post)"
      # Guardia: si es el repo del gateway, validar config; si quedo rota, revertir el pull
      if ($name -eq '.openclaw') {
        $v = & openclaw config validate 2>&1
        if ($v -notmatch 'Config valid') {
          git reset --hard $pre 2>&1 | Out-Null
          Log "$name config INVALIDA tras pull - revertido a $pre"
        }
      }
    }
  }

  # 3. Subir
  git push origin $branch 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Log "$name push ok" } else { Log "$name push FALLO" }
}
Log "---- ciclo terminado"
