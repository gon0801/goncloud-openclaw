@echo off
rem OpenClaw Gateway
rem Live bus → Gonserver BFF (tablero-fase :8787)
if exist "%USERPROFILE%\.openclaw\live-bus.env" (
  for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%USERPROFILE%\.openclaw\live-bus.env") do set "%%A=%%B"
)
set "HOME=C:\Users\ehven"
set "TMPDIR=C:\Users\ehven\AppData\Local\Temp"
set "NODE_OPTIONS="
set "OPENCLAW_GATEWAY_PORT=18789"
set "OPENCLAW_SYSTEMD_UNIT=openclaw-gateway.service"
set "OPENCLAW_WINDOWS_TASK_NAME=OpenClaw Gateway"
set "OPENCLAW_WINDOWS_TASK_HIDDEN_LAUNCHER=1"
set "OPENCLAW_SERVICE_MARKER=openclaw"
set "OPENCLAW_SERVICE_KIND=gateway"
"C:\Program Files\nodejs\node.exe" --max-old-space-size=4044 C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\index.js gateway --port 18789 --task-supervisor < NUL
