$ErrorActionPreference = 'Continue'
Write-Output '===STATUS==='
& openclaw gateway status 2>&1 | Out-String
Write-Output '===NET==='
netstat -ano | findstr '18789'
Write-Output '===AUTH==='
$j = Get-Content -Raw "$env:USERPROFILE\.openclaw\openclaw.json" | ConvertFrom-Json
Write-Output ("auth.mode=" + $j.gateway.auth.mode)
Write-Output ("token_present=" + ($null -ne $j.gateway.auth.token))
Write-Output '===LOCAL_CURL==='
try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:18789/runbook/tablero/12' -UseBasicParsing -TimeoutSec 15
  Write-Output ("local_http=" + [int]$r.StatusCode)
} catch {
  if ($_.Exception.Response) { Write-Output ("local_http=" + [int]$_.Exception.Response.StatusCode) }
  else { Write-Output ("local_err=" + $_.Exception.Message) }
}
Write-Output '===DOCTOR==='
$log = "$env:USERPROFILE\.openclaw\doctor-after-auth-none.log"
& openclaw doctor 2>&1 | Tee-Object -FilePath $log | Out-Null
Write-Output 'doctor_done'
Select-String -Path $log -Pattern 'warn|error|auth|security|mode|token|FAIL|pass|ok|none|listen' -CaseSensitive:$false | Select-Object -First 50 | ForEach-Object { $_.Line }
