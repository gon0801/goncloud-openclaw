$ErrorActionPreference = 'Continue'
$pkg = 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist'
Select-String -Path (Join-Path $pkg '*.mjs') -Pattern 'Refusing to bind gateway to lan without auth' |
  ForEach-Object {
    Write-Output ("HIT " + $_.Filename + ":" + $_.LineNumber)
    $lines = Get-Content $_.Path
    $start = [Math]::Max(0, $_.LineNumber - 25)
    $end = [Math]::Min($lines.Count - 1, $_.LineNumber + 25)
    for ($i=$start; $i -le $end; $i++) { Write-Output (("{0,5}: {1}" -f ($i+1), $lines[$i].Substring(0,[Math]::Min(220,$lines[$i].Length)))) }
  }
Write-Output '===BIND_GET==='
& openclaw config get gateway.bind 2>&1 | Out-String
& openclaw config get gateway.auth.mode 2>&1 | Out-String
node -e "const fs=require('fs'); const j=JSON.parse(fs.readFileSync(process.env.USERPROFILE+'\\\\.openclaw\\\\openclaw.json','utf8')); console.log(JSON.stringify({bind:j.gateway&&j.gateway.bind,mode:j.gateway&&j.gateway.auth&&j.gateway.auth.mode},null,2));"
# search for override env/flag near refuse
Select-String -Path (Join-Path $pkg '*.mjs') -Pattern 'without auth|ALLOW_INSECURE|allowUnauth|authRequired|bindLan|unsafeAuth|auth.mode' |
  Where-Object { $_.Line -match 'refuse|without auth|ALLOW|insecure|loopback' } |
  Select-Object -First 40 |
  ForEach-Object { $_.Filename + ':' + $_.LineNumber + ':' + $_.Line.Substring(0,[Math]::Min(220,$_.Line.Length)) }
