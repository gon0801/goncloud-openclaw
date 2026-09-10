& 'C:\Users\ehven\AppData\Roaming\npm\openclaw.cmd' doctor --fix --non-interactive --yes *> 'C:\Users\ehven\.openclaw\doctor-fix-20260910.log'
$ec = $LASTEXITCODE
('DONE_EXIT_' + $ec) | Out-File -Append 'C:\Users\ehven\.openclaw\doctor-fix-20260910.log'
exit $ec
