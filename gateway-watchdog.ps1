$ErrorActionPreference = "SilentlyContinue"

$gatewayPort = 18789
$gatewayTask = "OpenClaw Gateway"
$listener = Get-NetTCPConnection -State Listen -LocalPort $gatewayPort -ErrorAction SilentlyContinue

if (-not $listener) {
    Start-ScheduledTask -TaskName $gatewayTask
}
