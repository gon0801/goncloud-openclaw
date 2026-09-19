$ErrorActionPreference = 'Continue'
$files = @(
  'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\run-CiAIvodT.mjs',
  'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\server-runtime-config-Rusoy5br.mjs'
)
foreach ($f in $files) {
  Write-Output ("=== " + (Split-Path $f -Leaf) + " ===")
  $lines = Get-Content $f
  for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'Refusing to bind|without auth|authMode|hasSharedSecret|bindHost|trusted-proxy|mode === \"none\"|mode==="none"') {
      $start=[Math]::Max(0,$i-15); $end=[Math]::Min($lines.Count-1,$i+20)
      for ($j=$start; $j -le $end; $j++) {
        Write-Output (("{0,5}|{1}" -f ($j+1), $lines[$j].Substring(0,[Math]::Min(240,$lines[$j].Length))))
      }
      Write-Output '---'
    }
  }
}
