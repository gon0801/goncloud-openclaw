$ErrorActionPreference = 'Continue'
$plugin = Join-Path $env:USERPROFILE '.openclaw\tablero-runbook'
$envf = Join-Path $env:USERPROFILE '.openclaw\live-bus.env'
Write-Output ("live_bus_ts=" + (Test-Path (Join-Path $plugin 'live-bus.ts')))
Write-Output ("syncProgress=" + ((Select-String -Path (Join-Path $plugin 'index.ts') -Pattern 'syncProgress\(fase\)' -Quiet)))
Get-Content $envf | ForEach-Object {
  if ($_ -match '^([A-Z0-9_]+)=(.*)$') { Write-Output ("env_" + $Matches[1] + "_len=" + $Matches[2].Length); Set-Item -Path ("Env:"+$Matches[1]) -Value $Matches[2] }
}
Write-Output ("LIVE_BUS_URL=" + $env:LIVE_BUS_URL)
try { $g=Invoke-WebRequest http://127.0.0.1:18789/ -UseBasicParsing -TimeoutSec 8; Write-Output ("gw="+[int]$g.StatusCode) } catch { Write-Output ("gw_ERR "+$_.Exception.Message) }

# snapshot before
$before = (Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/')+'/api/runs') -UseBasicParsing -TimeoutSec 15).Content
$m = [regex]::Match($before, '"id":"fase-13".*?"updated_at":"([^"]+)"')
Write-Output ("before_fase13_updated=" + $m.Groups[1].Value)

Start-Sleep -Seconds 2
$headers = @{ Authorization = ('Bearer ' + $env:LIVE_WRITE_TOKEN) }
$r = Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/')+'/sync/progress/13') -Method POST -Headers $headers -ContentType 'application/json' -Body '{}' -UseBasicParsing -TimeoutSec 30
Write-Output ("sync13=" + [int]$r.StatusCode)
$j = $r.Content | ConvertFrom-Json
Write-Output ("sync_updated_at=" + $j.updated_at)

$after = (Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/')+'/api/runs') -UseBasicParsing -TimeoutSec 15).Content
$m2 = [regex]::Match($after, '"id":"fase-13".*?"updated_at":"([^"]+)"')
Write-Output ("after_fase13_updated=" + $m2.Groups[1].Value)
Write-Output ("updated_changed=" + ($m.Groups[1].Value -ne $m2.Groups[1].Value))

# live page
try { $l=Invoke-WebRequest -Uri ($env:LIVE_BUS_URL.TrimEnd('/')+'/live') -UseBasicParsing -TimeoutSec 10; Write-Output ("live="+[int]$l.StatusCode+" bytes="+$l.Content.Length) } catch { Write-Output ("live_ERR "+$_.Exception.Message) }
