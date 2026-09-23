# Fase 18: corte limpio del gateway Windows

Ejecutor: opera desde la Mac por el alias SSH `gwpc`; David no está al teclado.
Hereda `docs/runbooks/base-openclaw.md` v1.2. Este documento cubre solo el
corte Windows de 18.2, 18.4 y la reversa. No inicia la autonomía, el panel ni
Hermes. **Estado: borrador, no ejecutar el corte hasta cerrar las compuertas.**
El gateway está caído, por lo que la excepción a `loop-autopilot.md` §§1, 8 y
12 es usar el PR y este recibo para progreso; `main`, el tablero y Telegram
del gateway no son mecanismos de control durante el corte.

## Autoridad y fuente

La fila 18.2 y la fila 18.4 del plan en el PR #131 mandan sobre este texto.
El inventario del PR #132 y su respaldo privado son la fuente de rutas y de
los ocho agentes. El corte real exige un comentario de David en el PR de este
runbook con el texto `AUTORIZO CORTE gwpc <sha> <inicio-ET> <fin-ET>`, donde
`<sha>` es el commit aprobado y las horas usan `America/New_York`. El comentario
cita la reversa a `.openclaw-old-20260922`; sin esos campos, se hace
solo preflight. La hora de Windows se lee con `Get-Date`; zona
`America/New_York`, no la zona de la Mac.

| Operación | Alcance | Decisión |
|---|---|---|
| SSH y lectura de estado, tareas y metadatos | `gwpc`, sin valores de secretos | Aprobado |
| Verificar backup y restauración aislada | rutas privadas citadas abajo | Aprobado |
| Deshabilitar sync/watchdog | ya deshabilitados; no reactivar antes de aceptación | Aprobado |
| Retirar tarea Gateway y renombrar estado viejo | solo en ventana y con autorización operativa | Negado por ahora |
| `uninstall --all`, borrado recursivo, importar SQLite/sesiones o copiar credenciales entre hosts | cualquier ruta | Negado |

## Preflight de solo lectura

El shell SSH remoto es `cmd.exe`; para no romper comillas, define esta
función en la zsh de la Mac. Se probó con `Get-Date` y `Get-ScheduledTask`:

```bash
gwps18() {
  local encoded18
  encoded18=$(printf '$ProgressPreference = "SilentlyContinue"; $ErrorActionPreference = "Stop"; %s' "$1" |
    iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  ssh -o BatchMode=yes -o ConnectTimeout=4 gwpc powershell -NoProfile -NonInteractive -EncodedCommand "$encoded18"
}
```

Un fallo de SSH detiene el corte; no se intenta por IP sin alias. Ejecuta
cada línea por separado y guarda el resultado en el recibo privado:

```bash
gwps18 'openclaw --version'
gwps18 'npm ls -g openclaw --depth=0'
gwps18 'openclaw uninstall --service --dry-run --non-interactive --yes'
gwps18 'openclaw uninstall --all --dry-run --non-interactive --yes'
gwps18 "Get-FileHash -LiteralPath 'C:\Users\ehven\.openclaw-recovery\2026-09-22T22-26-23.681-04-00-openclaw-backup.tar.gz' -Algorithm SHA256"
gwps18 "Get-ScheduledTask -TaskName 'OpenClaw Gateway','OpenClaw Gateway Watchdog','GoncloudRepoSync' | Select-Object TaskName,State"
gwps18 'Test-NetConnection 127.0.0.1 -Port 18789 -InformationLevel Quiet'
gwps18 "Test-Path 'C:\Users\ehven\.openclaw-old-20260922'"
gwps18 "Test-Path 'C:\Users\ehven\.openclaw-recovery\failed-new-20260922'"
gwps18 "Test-Path 'C:\Users\ehven\.openclaw'"
gwps18 "Test-Path 'C:\Users\ehven\.openclaw-recovery\staging-20260922'"
gwps18 "Test-Path 'C:\Users\ehven\.openclaw-recovery\staging-20260922\2026-09-22T22-26-23.681-04-00-openclaw-backup\payload\windows\C\Users\ehven\.openclaw\state\openclaw.sqlite'"
gwps18 "Test-Path 'C:\Users\ehven\.openclaw-recovery\staging-20260922\2026-09-22T22-26-23.681-04-00-openclaw-backup\payload\windows\C\Users\ehven\.openclaw\agents\adversary.HELD-20260922\agent\openclaw-agent.sqlite'"
gwps18 "Test-Path 'C:\Users\ehven\.openclaw-recovery\git-20260922.bundle'"
gwps18 "(Get-ChildItem -LiteralPath 'C:\Users\ehven\.openclaw-recovery\task-xml-20260922' -Filter '*.xml').Count"
gwps18 "(Get-Item -LiteralPath 'C:\Users\ehven\.openclaw-recovery\openclaw-2026.9.5.tgz').Length"
gwps18 "Get-FileHash -LiteralPath 'C:\Users\ehven\.openclaw-recovery\openclaw-2026.9.5.tgz' -Algorithm SHA256"
gwps18 'node C:\Users\ehven\.openclaw-recovery\npm-probe-20260922\node_modules\openclaw\openclaw.mjs --version'
gwps18 'Get-TimeZone'
gwps18 'Get-Date'
```

Salida requerida: OpenClaw `2026.9.5 (ec9c1a1)` en npm global; `--service`
enumera solo Gateway; `--all` enumera también el estado y ocho workspaces,
pero **nunca se ejecuta sin `--dry-run`**; el backup ya dio `ok=true` al
crear y restaurar. Su SHA-256 debe seguir siendo
`9D91AF302A461CF412C17E5CFD94771E0A5FF98CD17BE63EB96F3DF40B70587A`;
watchdog y sync
`Disabled`; `Test-NetConnection` devuelve `False`; destino viejo renombrado
ausente, `failed-new-20260922` ausente y estado canónico presente.
El CLI aislado debe responder `2026.9.5 (ec9c1a1)`; el tarball pesa 72.453.925
bytes y su SHA-256 es
`1FB6EF4FAE447AF14F1E3B1028334F39146D181A66A4CCE2848D4F741C636340`.
La zona debe ser `Eastern Standard Time` (Windows cambia a horario de verano).
Las cuatro pruebas `Test-Path` de staging, bundle y bases deben dar `True`;
el restore previo registró 27.341 entradas y cero symlinks. El conteo XML
debe ser 6. No publiques su contenido. La compuerta de 18.3 exige PR de código
aceptado, CI completo, allowlist sin archivos `unknown` y configuración nueva
con ocho arreglos ordenados iguales a la captura elegida por David.

## Corte, solo tras todas las compuertas

1. Registra hora, SHA de 18.3, tamaño/hash del backup y estado de tareas.
   No cierres SSH hasta tener una segunda conexión funcional. No uses el
   gateway caído como canal de reversa.
2. Con puerto libre y sync/watchdog deshabilitados, ejecuta
   `gwps18 'openclaw uninstall --service --non-interactive --yes'`. Comprueba que
   desapareció solo `OpenClaw Gateway` y que el estado viejo sigue presente.
   Esta orden no pregunta: el `--service --dry-run` del preflight es la
   última ocasión para rechazar un objetivo distinto.
3. Renombra el estado con
   `gwps18 "Rename-Item -LiteralPath 'C:\Users\ehven\.openclaw' -NewName '.openclaw-old-20260922' -ErrorAction Stop"`.
   Comprueba que `Test-Path 'C:\Users\ehven\.openclaw-old-20260922'` da
   `True` y `Test-Path 'C:\Users\ehven\.openclaw'` da `False`.
   No borres esa carpeta al cerrar la fase.
4. Reinstala el paquete npm global desde el tarball verificado:
   `gwps18 'npm uninstall -g openclaw'` y después
   `gwps18 "npm install -g 'C:\Users\ehven\.openclaw-recovery\openclaw-2026.9.5.tgz' --offline --no-audit --no-fund"`.
   `openclaw --version` debe devolver `2026.9.5 (ec9c1a1)`. Crea el
   nuevo estado canónico. El archivo nuevo de configuración viene del PR
   18.3 aprobado; solo se copian por allowlist los agentes, workspaces y
   skills clasificados. No se copia `openclaw.json`, SQLite, sesiones,
   navegador ni `credentials` del estado viejo en bloque.
5. Reautoriza cada proveedor mediante su mecanismo oficial. Si requiere
   interacción humana, deja el servicio sin tráfico y declara el proveedor
   pendiente; no sustituyas modelos. Los canales y el sync siguen deshabilitados
   hasta 18.5. Instala la tarea con
   `gwps18 'openclaw gateway install --port 18789 --runtime node'` solo cuando
   `gwps18 'openclaw config validate --json'` termine con código 0. Comprueba
   `gwps18 'openclaw doctor'`, `gwps18 'openclaw gateway status --json'` y
   `gwps18 'openclaw gateway call health --json --timeout 10000'`.
   El PR 18.3 debe proveer la comparación automática de los ocho agentes,
   sus roles y cadenas ordenadas; no declares aceptación con solo salud.

## Reversa

Solo antes de habilitar canales o sync, ejecuta estas órdenes mediante la
función `gwps18` de arriba, una por línea. La carpeta
`failed-new-20260922` debe seguir ausente. El XML exportado es la vía de
reversa incluso si npm dejó de resolver `openclaw`:

```bash
gwps18 '$t = Get-ScheduledTask -TaskName "OpenClaw Gateway" -ErrorAction SilentlyContinue; if ($t -and $t.State -eq "Running") { $t | Stop-ScheduledTask }'
gwps18 '$t = Get-ScheduledTask -TaskName "OpenClaw Gateway" -ErrorAction SilentlyContinue; if ($t) { $t | Unregister-ScheduledTask -Confirm:$false }'
gwps18 'Test-NetConnection 127.0.0.1 -Port 18789 -InformationLevel Quiet'
gwps18 "Move-Item -LiteralPath 'C:\Users\ehven\.openclaw' -Destination 'C:\Users\ehven\.openclaw-recovery\failed-new-20260922' -ErrorAction Stop"
gwps18 "Rename-Item -LiteralPath 'C:\Users\ehven\.openclaw-old-20260922' -NewName '.openclaw' -ErrorAction Stop"
gwps18 "schtasks.exe /Create /TN '\OpenClaw Gateway' /XML 'C:\Users\ehven\.openclaw-recovery\task-xml-20260922\OpenClaw Gateway.xml'"
gwps18 "schtasks.exe /Query /TN '\OpenClaw Gateway' /FO LIST"
```

La consulta del puerto debe dar `False` antes del `Move-Item`; si da
`True`, no muevas carpetas ni mates un PID sin comprobar su dueño. Después,
la tarea debe figurar `Ready` y apuntar al `gateway.vbs` restaurado. No
declares salud si el gateway viejo sigue fallando. Tras habilitar canales o
sync, no uses esta reversa automática: conserva ambos estados y reconcilia
mensajes nuevos antes de cualquier retorno; nunca sobrescribas SQLite.

## Atores y cierre

| Situación | Acción |
|---|---|
| Backup, staging, bundle, XML o autorización ausente | No iniciar corte; conservar estado actual y reportar el dato faltante. |
| La ruta de destino del renombrado ya existe | No sobrescribirla; detener corte y elegir otro nombre en una revisión del runbook. |
| `uninstall --service` toca estado o workspaces | Detener y conservar el estado; no ampliar a `--all`. |
| Paquete, auth, salud o agente falla antes de tráfico | Ejecutar reversa previa a tráfico; adjuntar salida sin secretos. |
| Falla después de tráfico | Conservar ambos estados; no reimportar SQLite; emitir recibo de reconciliación. |
| SSH se pierde | No repetir comandos de efecto incierto; reconectar y leer tarea, rutas y puerto. |

El resultado de 18.4 es el gateway nuevo sano y los ocho agentes/cadenas
comprobados por sus rutas. El encargo real y dos ciclos de sync son de 18.5:
requieren otra autorización antes de producir tráfico. Hasta esa prueba,
David ve "OpenClaw recuperado; autonomía y panel pendientes", no "goal
completo".

## Clases de comando

| Clase | Uso |
|---|---|
| `ssh` | preflight, corte y reversa en `gwpc` |
| `gh` | PR, SHA, aprobación y CI de 18.3 |
