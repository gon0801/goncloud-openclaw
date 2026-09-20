$ErrorActionPreference = 'Stop'
$Repo = 'C:\Users\ehven\.openclaw\workspace'
$Feature = 'feat/goncloud-operating-map'
$BackupDir = 'C:\Users\ehven\.openclaw\backups\goncloud-map-before-merge-20260908'
$ExpectedToolsHash = 'CB7FBB37414F9FAC4E36BC82C73CC4F30FB1A614010CD79DE03C729173833DBF'

Set-Location $Repo
if ((git branch --show-current).Trim() -ne 'master') { throw 'Active workspace is not on master' }
if ((git rev-parse HEAD).Trim() -ne '869ae4108c34d6c431033b30932d5d7fe9f67c8a') { throw 'Unexpected master HEAD' }
if (git status --porcelain=v1 --untracked-files=no) { throw 'Tracked workspace changes exist' }
if (git remote) { throw 'Unexpected Git remote; PR decision must be revisited' }

$Tools = Join-Path $Repo 'TOOLS.md'
if (-not (Test-Path -LiteralPath $Tools -PathType Leaf)) { throw 'Existing TOOLS.md is missing' }
if ((Get-FileHash -Algorithm SHA256 $Tools).Hash -ne $ExpectedToolsHash) { throw 'TOOLS.md changed after preservation review' }
if (Test-Path -LiteralPath $BackupDir) { throw "Backup path already exists: $BackupDir" }

New-Item -ItemType Directory -Path $BackupDir | Out-Null
Move-Item -LiteralPath $Tools -Destination (Join-Path $BackupDir 'TOOLS.md')

try {
    git merge --squash $Feature
    if ($LASTEXITCODE -ne 0) { throw 'Squash merge failed' }
    git -c user.name=Claw -c user.email=claw@openclaw.local commit -m 'feat: add GonCloud operating map'
    if ($LASTEXITCODE -ne 0) { throw 'Merge commit failed' }
}
catch {
    if (-not (Test-Path -LiteralPath $Tools) -and (Test-Path -LiteralPath (Join-Path $BackupDir 'TOOLS.md'))) {
        Move-Item -LiteralPath (Join-Path $BackupDir 'TOOLS.md') -Destination $Tools
    }
    throw
}

powershell -NoProfile -ExecutionPolicy Bypass -File tests\goncloud-ops\test-static-map.ps1
if ($LASTEXITCODE -ne 0) { throw 'Merged static-map contract failed' }

$Skill = openclaw skills info goncloud-ops --agent main --json | ConvertFrom-Json
if ($Skill.name -ne 'goncloud-ops' -or -not $Skill.eligible) { throw 'goncloud-ops is not eligible in main workspace' }
Write-Output 'goncloud-skill-main=eligible'

git show --stat --oneline HEAD
git status --short
