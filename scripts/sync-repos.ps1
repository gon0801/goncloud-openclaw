# sync-repos.ps1 - sincroniza los 4 repos goncloud con GitHub (pull + commit local + push)
$log = 'C:\Users\ehven\.openclaw\logs\sync-repos.log'
$repos = @(
  'C:\Users\ehven\.openclaw',
  'C:\Users\ehven\.openclaw\workspace',
  'C:\Users\ehven\.openclaw\workspace-ingenieria',
  'C:\Users\ehven\.openclaw\workspace-operaciones'
)
function Log($msg) { Add-Content $log ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) }

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
  $dirty = git status --porcelain
  if ($dirty) {
    $commitOut = git -c user.name="openclaw-auto" -c user.email="ehventasmx@gmail.com" commit -m "auto: snapshot $name $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 2>&1
    if ($LASTEXITCODE -eq 0) {
      Log "$name commit local auto"
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
