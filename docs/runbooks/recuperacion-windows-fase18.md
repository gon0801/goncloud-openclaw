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

Cada comando corre en Windows dentro de PowerShell. Desde la Mac, la forma es
`ssh -o BatchMode=yes -o ConnectTimeout=4 gwpc 'powershell -NoProfile -NonInteractive -Command "<comando>"'`.
`<comando>` es una línea de este bloque, con sus comillas simples intactas.
Por ejemplo: `ssh -o BatchMode=yes -o ConnectTimeout=4 gwpc 'powershell -NoProfile -NonInteractive -Command "Get-Date"'`.
El shell SSH remoto sin ese prefijo es `cmd.exe` y rechaza `Get-Date`.
Un fallo de SSH detiene el corte; no se intenta por IP sin alias.
Ejecuta las líneas por separado y conserva la salida
en un recibo privado bajo `C:\Users\ehven\.openclaw-recovery`:

```powershell
openclaw --version
npm ls -g openclaw --depth=0
openclaw uninstall --service --dry-run --non-interactive --yes
openclaw uninstall --all --dry-run --non-interactive --yes
openclaw backup verify --json "C:\Users\ehven\.openclaw-recovery\2026-09-22T22-26-23.681-04-00-openclaw-backup.tar.gz"
Get-ScheduledTask -TaskName 'OpenClaw Gateway','OpenClaw Gateway Watchdog','GoncloudRepoSync' | Select-Object TaskName,State
Test-NetConnection 127.0.0.1 -Port 18789 -InformationLevel Quiet
Test-Path 'C:\Users\ehven\.openclaw-old-20260922'
Test-Path 'C:\Users\ehven\.openclaw'
Test-Path 'C:\Users\ehven\.openclaw-recovery\git-20260922.bundle'
(Get-ChildItem -LiteralPath 'C:\Users\ehven\.openclaw-recovery\task-xml-20260922' -Filter '*.xml').Count
Get-FileHash -LiteralPath 'C:\Users\ehven\.openclaw-recovery\openclaw-2026.9.5.tgz' -Algorithm SHA256
Get-Date
```

Salida requerida: OpenClaw `2026.9.5 (ec9c1a1)` en npm global; `--service`
enumera solo Gateway; `--all` enumera también el estado y ocho workspaces,
pero **nunca se ejecuta sin `--dry-run`**; backup `ok=true`; watchdog y sync
`Disabled`; `Test-NetConnection` devuelve `False`; destino viejo renombrado
ausente y estado canónico presente. El tarball npm privado pesa 72.453.925
bytes y su SHA-256 es
`1FB6EF4FAE447AF14F1E3B1028334F39146D181A66A4CCE2848D4F741C636340`.
El backup restaurado en staging tiene 27.341 entradas
y cero symlinks. El bundle debe existir y el conteo XML debe ser 6; no
publiques su contenido. La compuerta
de 18.3 requiere PR de código aceptado, CI completo y archivo de configuración
nueva con ocho arreglos ordenados iguales a la captura elegida por David.

## Corte, solo tras todas las compuertas

1. Registra hora, SHA de 18.3, tamaño/hash del backup y estado de tareas.
   No cierres SSH hasta tener una segunda conexión funcional. No uses el
   gateway caído como canal de reversa.
2. Con puerto libre y sync/watchdog deshabilitados, ejecuta
   `openclaw uninstall --service --non-interactive --yes`. Comprueba que
   desapareció solo `OpenClaw Gateway` y que el estado viejo sigue presente.
   Si el CLI anuncia otro objetivo, detente antes de confirmar.
3. Renombra el estado con
   `Rename-Item -LiteralPath 'C:\Users\ehven\.openclaw' -NewName '.openclaw-old-20260922' -ErrorAction Stop`.
   Comprueba que `Test-Path 'C:\Users\ehven\.openclaw-old-20260922'` da
   `True` y `Test-Path 'C:\Users\ehven\.openclaw'` da `False`.
   No borres esa carpeta al cerrar la fase.
4. Reinstala el paquete npm global desde el tarball verificado:
   `npm uninstall -g openclaw` y después
   `npm install -g 'C:\Users\ehven\.openclaw-recovery\openclaw-2026.9.5.tgz'`.
   `openclaw --version` debe devolver `2026.9.5 (ec9c1a1)`. Crea el
   nuevo estado canónico. El archivo nuevo de configuración viene del PR
   18.3 aprobado; solo se copian por allowlist los agentes, workspaces y
   skills clasificados. No se copia `openclaw.json`, SQLite, sesiones,
   navegador ni `credentials` del estado viejo en bloque.
5. Reautoriza cada proveedor/canal mediante su mecanismo oficial. Si requiere
   interacción humana, deja el servicio sin tráfico y declara el proveedor
   pendiente; no sustituyas modelos. Instala la tarea con
   `openclaw gateway install --port 18789 --runtime node` solo cuando la
   configuración valide. Comprueba `doctor`, `gateway status --json`, salud
   200/200 y los ocho agentes. El sync sigue deshabilitado hasta 18.5.

## Reversa

Antes de tráfico nuevo: detén la tarea nueva, preserva el estado nuevo en
`C:\Users\ehven\.openclaw-recovery\failed-new-<fecha>`, devuelve la carpeta
vieja al nombre canónico e instala la tarea Gateway desde la versión dueña.
Comprueba que el puerto y la tarea vuelven al estado anterior; no declares
salud si el gateway viejo sigue fallando. Después de tráfico nuevo, **no**
sobrescribas la base nueva con la vieja: conserva ambas y restaura servicio por
componente con recibo de mensajes, para no perder entradas recientes.

## Atores y cierre

| Situación | Acción |
|---|---|
| Backup, staging, bundle, XML o autorización ausente | No iniciar corte; conservar estado actual y reportar el dato faltante. |
| La ruta de destino del renombrado ya existe | No sobrescribirla; detener corte y elegir otro nombre en una revisión del runbook. |
| `uninstall --service` toca estado o workspaces | Detener y conservar el estado; no ampliar a `--all`. |
| Paquete, auth, salud o agente falla antes de tráfico | Ejecutar reversa previa a tráfico; adjuntar salida sin secretos. |
| Falla después de tráfico | Conservar ambos estados; no reimportar SQLite; emitir recibo de reconciliación. |
| SSH se pierde | No repetir comandos de efecto incierto; reconectar y leer tarea, rutas y puerto. |

El resultado visible para David en 18.4 es un encargo pequeño respondido por
`main` desde el gateway nuevo, con los ocho agentes y cadenas comprobados.
Antes de eso, el estado es "preparación", aunque el PR o CI estén verdes.

## Clases de comando

| Clase | Uso |
|---|---|
| `ssh` | preflight, corte y reversa en `gwpc` |
| `gh` | PR, SHA, aprobación y CI de 18.3 |
