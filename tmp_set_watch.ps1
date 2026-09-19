$ErrorActionPreference = 'Continue'
$p = "$env:USERPROFILE\.openclaw\openclaw.json"
Write-Output ("mtime_before=" + (Get-Item $p).LastWriteTime.ToString('o') + " len=" + (Get-Item $p).Length)
node "$env:USERPROFILE\.openclaw\tmp_edit_mode.js"
Write-Output ("mtime_after_edit=" + (Get-Item $p).LastWriteTime.ToString('o') + " len=" + (Get-Item $p).Length)
$j = Get-Content -Raw $p | ConvertFrom-Json
Write-Output ("mode_after_edit=" + $j.gateway.auth.mode)
# check competing config files
Get-ChildItem "$env:USERPROFILE\.openclaw\openclaw.json*" | Sort-Object LastWriteTime -Descending | ForEach-Object {
  Write-Output ("file=" + $_.Name + " mtime=" + $_.LastWriteTime.ToString('o') + " len=" + $_.Length)
}
# Does openclaw have a config set command?
& openclaw config get gateway.auth.mode 2>&1 | Out-String | Write-Output
& openclaw config set gateway.auth.mode none 2>&1 | Out-String | Write-Output
Start-Sleep -Seconds 2
& openclaw config get gateway.auth.mode 2>&1 | Out-String | Write-Output
$j2 = Get-Content -Raw $p | ConvertFrom-Json
Write-Output ("mode_after_cli=" + $j2.gateway.auth.mode + " mtime=" + (Get-Item $p).LastWriteTime.ToString('o'))
