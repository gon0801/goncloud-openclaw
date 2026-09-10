$ErrorActionPreference = 'Stop'
$targetUser = 'ehven'
$logDirectory = 'C:\ProgramData\OpenClaw'
$logPath = Join-Path $logDirectory 'restore-console.log'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Write-RestoreLog([string]$Message) {
    Add-Content -Path $logPath -Encoding UTF8 -Value ('{0:o} {1}' -f (Get-Date), $Message)
}

$lines = @(& "$env:SystemRoot\System32\quser.exe" $targetUser 2>$null)
if (-not $lines) {
    Write-RestoreLog 'No session found for ehven; no action taken.'
    exit 0
}

$match = $null
foreach ($line in $lines | Select-Object -Skip 1) {
    if ($line -match '^\s*>?ehven\s+(?:\S+\s+)?(?<Id>\d+)\s+(?:Disc|Disconnected|Desconectado)\b') {
        $match = $Matches
        break
    }
}

if (-not $match) {
    Write-RestoreLog 'No disconnected ehven session found; no action taken.'
    exit 0
}

$sessionId = [int]$match.Id
Write-RestoreLog "Restoring disconnected ehven session $sessionId to console."
& "$env:SystemRoot\System32\tscon.exe" $sessionId /dest:console
if ($LASTEXITCODE -ne 0) { throw "tscon failed with exit code $LASTEXITCODE" }
Write-RestoreLog "Session $sessionId restored to console."
