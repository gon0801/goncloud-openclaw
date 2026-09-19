$ErrorActionPreference = 'Continue'
$f = 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\server-runtime-config-Rusoy5br.mjs'
$lines = Get-Content $f
Write-Output '===FULL_FILE==='
$lines | ForEach-Object -Begin {$i=0} -Process { $i++; "{0,4}|{1}" -f $i, $_.Substring(0,[Math]::Min(260,$_.Length)) }
Write-Output '===AUTH_RESOLVE==='
$f2 = 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\auth-resolve-DGHwQAtC.mjs'
Get-Content $f2 | ForEach-Object -Begin {$i=0} -Process { $i++; if ($i -le 120) { "{0,4}|{1}" -f $i, $_.Substring(0,[Math]::Min(260,$_.Length)) } }
Write-Output '===TAILSCALE_CFG==='
& openclaw config get gateway.tailscale 2>&1 | Out-String
node -e "const fs=require('fs'); const j=JSON.parse(fs.readFileSync(process.env.USERPROFILE+'\\\\.openclaw\\\\openclaw.json','utf8')); console.log(JSON.stringify(j.gateway&&j.gateway.tailscale||null,null,2)); console.log('bind', j.gateway&&j.gateway.bind);"
