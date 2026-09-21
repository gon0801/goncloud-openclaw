@echo off
rem OpenClaw Node Host
set "TMPDIR=C:\Users\ehven\AppData\Local\Temp"
set "OPENCLAW_LAUNCHD_LABEL=ai.openclaw.node"
set "OPENCLAW_SYSTEMD_UNIT=openclaw-node"
set "OPENCLAW_WINDOWS_TASK_NAME=OpenClaw Node"
set "OPENCLAW_WINDOWS_TASK_HIDDEN_LAUNCHER=1"
set "OPENCLAW_TASK_SCRIPT_NAME=node.cmd"
set "OPENCLAW_LOG_PREFIX=node"
set "OPENCLAW_SERVICE_MARKER=openclaw"
set "OPENCLAW_SERVICE_KIND=node"
"C:\Program Files\nodejs\node.exe" C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist\index.js node run --host 127.0.0.1 --port 18789 --no-tls < NUL
