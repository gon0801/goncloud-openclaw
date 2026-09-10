$ErrorActionPreference = 'Stop'
$targetUser = 'ehven'
$eventUser = "$env:COMPUTERNAME\$targetUser"
$logDirectory = 'C:\ProgramData\OpenClaw'
$logPath = Join-Path $logDirectory 'restore-console.log'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Write-RestoreLog([string]$Message) {
    Add-Content -Path $logPath -Encoding UTF8 -Value ('{0:o} {1}' -f (Get-Date), $Message)
}

function Get-DisconnectedSessionId {
    $lines = @(& "$env:SystemRoot\System32\quser.exe" $targetUser 2>$null)
    foreach ($line in $lines | Select-Object -Skip 1) {
        if ($line -match '^\s*>?ehven\s+(?:\S+\s+)?(?<Id>\d+)\s+(?:Disc|Disconnected|Desconectado)\b') {
            return [int]$Matches.Id
        }
    }
    return $null
}

function Get-LatestRemoteDisconnect([int]$SessionId) {
    $xpath = "*[System[EventID=24] and UserData[EventXML[User='$eventUser' and SessionID='$SessionId']]]"
    try {
        $events = Get-WinEvent -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -FilterXPath $xpath -ErrorAction Stop
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return $null }
        throw
    }
    foreach ($event in $events) {
        $data = ([xml]$event.ToXml()).Event.UserData.EventXML
        # Validate again after parsing; LOCAL and malformed addresses cannot authorize restoration.
        $address = $null
        if ([string]$data.User -ine $eventUser -or [string]$data.SessionID -ne [string]$SessionId) { continue }
        if (-not [Net.IPAddress]::TryParse([string]$data.Address, [ref]$address)) { continue }
        if ([Net.IPAddress]::IsLoopback($address)) { continue }
        return $event
    }
    return $null
}

# The trigger delay is not a grace guarantee: an older task can still be running.
# Re-read live session/event state on every pass. Leave headroom below task PT2M.
$deadline = (Get-Date).ToUniversalTime().AddSeconds(110)
while ((Get-Date).ToUniversalTime() -lt $deadline) {
    $sessionId = Get-DisconnectedSessionId
    if ($null -eq $sessionId) {
        Write-RestoreLog 'No disconnected ehven session found; no action taken.'
        exit 0
    }
    $latest = Get-LatestRemoteDisconnect $sessionId
    if ($null -eq $latest) {
        Write-RestoreLog "No remote disconnect event for ehven session $sessionId; no action taken."
        exit 0
    }
    if (((Get-Date).ToUniversalTime() - $latest.TimeCreated.ToUniversalTime()).TotalSeconds -ge 30) {
        # Recheck after event lookup so a reconnect or newer disconnect cancels eligibility.
        if ((Get-DisconnectedSessionId) -ne $sessionId) { continue }
        $latest = Get-LatestRemoteDisconnect $sessionId
        if ($null -ne $latest -and ((Get-Date).ToUniversalTime() - $latest.TimeCreated.ToUniversalTime()).TotalSeconds -ge 30) {
            Write-RestoreLog "Restoring disconnected ehven session $sessionId to console; remote Event24 record $($latest.RecordId), at $($latest.TimeCreated.ToUniversalTime().ToString('o')), grace >=30s."
            & "$env:SystemRoot\System32\tscon.exe" $sessionId /dest:console
            if ($LASTEXITCODE -ne 0) { throw "tscon failed with exit code $LASTEXITCODE" }
            Write-RestoreLog "Session $sessionId restored to console."
            exit 0
        }
    }
    Start-Sleep -Milliseconds 1000
}
Write-RestoreLog 'Grace wait reached its 110-second budget; no session restored.'
