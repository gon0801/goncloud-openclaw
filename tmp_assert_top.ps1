$f = 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\server-runtime-config-Rusoy5br.mjs'
Get-Content $f -TotalCount 50 | ForEach-Object -Begin {$i=0} -Process { $i++; "{0,4}|{1}" -f $i, $_ }
Write-Output '===RUN_REFUSE==='
$f2 = Get-ChildItem 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\run-*.mjs' | Where-Object { (Select-String -Path $_.FullName -Pattern 'Refusing to bind gateway' -Quiet) }
foreach ($x in $f2) {
  Write-Output $x.Name
  $lines = Get-Content $x.FullName
  for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'Refusing to bind gateway') {
      for ($j=[Math]::Max(0,$i-30); $j -le [Math]::Min($lines.Count-1,$i+15); $j++) {
        Write-Output (("{0,5}|{1}" -f ($j+1), $lines[$j]))
      }
    }
  }
}
