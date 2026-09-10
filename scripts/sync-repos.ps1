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
  git add -A 2>$null
  $dirty = git status --porcelain
  if ($dirty) {
    git -c user.name="openclaw-auto" -c user.email="ehventasmx@gmail.com" commit -m "auto: snapshot $name $(Get-Date -Format 'yyyy-MM-dd HH:mm')" 2>&1 | Out-Null
    Log "$name commit local auto"
  }

  # 2. Bajar cambios de GitHub (ediciones desde la Mac)
  git fetch origin 2>&1 | Out-Null
  git pull --rebase origin $branch 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    git rebase --abort 2>$null
    Log "$name CONFLICTO en pull - se deja como estaba, revisar a mano"
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
