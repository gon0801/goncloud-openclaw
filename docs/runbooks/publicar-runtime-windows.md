# Publicar `main` al runtime Windows (sync seguro U1)

Cómo llega lo mergeado en `gon0801/goncloud-openclaw` al gateway Windows desde
la separación del runtime del 22 de septiembre de 2026
(`docs/spec/00-project-spec.md`, «Propiedad del runtime Windows»). **Mergear a
`main` ya no despliega**: el sync de cada 2 h (`scripts/sync-repos.ps1`, tarea
`GoncloudRepoSync`) está deshabilitado y `C:\Users\ehven\.openclaw` ya no es un
clon git. El único camino es el pipeline de `scripts/sync-seguro/`, que se
puede ejecutar cualquier agente sin pedir permiso adicional.

## Qué publica y qué no

Solo lo que nombra la allowlist de `scripts/sync-seguro/selection-policy.mjs`:

- `summa-gate/**` y `tablero-runbook/**`
- `agents/<agente>/agent/workshop-skills/**`
- `gateway-watchdog.ps1`

Todo lo demás del repo **no llega al runtime**: `scripts/`, `docs/`, crons,
config, credenciales y bases. Un cambio que solo toca `scripts/` o `docs/`
queda desplegado con solo actualizar el checkout fuente (paso 1). Nunca borra:
un archivo vivo que no está en `main` se queda como está.

Publicar archivos **no activa plugins**. El gateway carga `summa-gate` y
`tablero-runbook` solo si `plugins.load.paths` los nombra y su entrada está
`enabled`. Eso es config y se cambia aparte (ver «Activar plugins»).

## Dónde vive cada cosa (leído en el host el 2026-09-24)

| Qué | Ruta |
|---|---|
| Checkout fuente | `C:\Users\ehven\src\goncloud-openclaw` (rama `main`, `core.autocrlf=true`) |
| Runtime vivo | `C:\Users\ehven\.openclaw` |
| Node | `C:\Program Files\nodejs\node.exe` (v24) |
| Publicaciones | `C:\Users\ehven\.openclaw-publish\<id>\` (una carpeta por publicación, nunca se reutiliza) |
| Registro de instalados | `C:\Users\ehven\.openclaw\.ledger\sync-seguro-installed.json` (lo crea la primera publicación) |

Ninguna carpeta de staging o transacción puede tener un componente llamado
`.openclaw`: los scripts la rechazan (`live runtime cannot be recovery …`).
Por eso la raíz es `.openclaw-publish`.

## Antes de empezar

1. El commit está en `origin/main` con CI verde, y es la **punta** de
   `origin/main`: ese SHA completo es el `$sha` del bloque. Si `main` avanzó
   antes de publicar, vuelve a comprobar el SHA y sus checks.
2. Cualquier agente puede publicar este SHA sin orden adicional ni espera por una ventana de cron.

## Publicar (PowerShell en el host Windows)

Todo el bloque se corre de una vez. Se detiene en el primer error y no toca el
runtime hasta el paso 5.

```powershell
$ErrorActionPreference = 'Stop'
$sha = '<SHA completo seleccionado>'
$src = 'C:\Users\ehven\src\goncloud-openclaw'
$rt  = 'C:\Users\ehven\.openclaw'
$id  = Get-Date -Format 'yyyyMMdd-HHmmss'
$pub = "C:\Users\ehven\.openclaw-publish\$id"
$ss  = "$src\scripts\sync-seguro"
function Paso($n) { if ($LASTEXITCODE -ne 0) { throw "paso $n salió con $LASTEXITCODE" } }

# 1. Poner la fuente exactamente en el SHA seleccionado (solo fast-forward de main)
if ((git -C $src rev-parse --abbrev-ref HEAD) -ne 'main') { throw 'la fuente no está en main' }
if (git -C $src status --porcelain) { throw 'fuente con cambios sin commitear' }
git -C $src fetch origin main; Paso 1
if ((git -C $src rev-parse origin/main) -ne $sha) { throw 'origin/main no es el SHA seleccionado: main avanzó o el SHA está mal' }
git -C $src merge --ff-only $sha; Paso 1
if ((git -C $src rev-parse HEAD) -ne $sha) { throw 'la fuente no quedó en el SHA seleccionado' }
"fuente en " + (git -C $src log -1 --format='%h %s')

# 2. Manifiesto
New-Item -ItemType Directory -Force $pub | Out-Null
node "$ss\build-selection.mjs" $src "$pub\selection.json"; Paso 2

# 3. Validar sin escribir
node "$ss\stage-selected.mjs" "$pub\selection.json" $src "$pub\stage"; Paso 3

# 4. Staging fuera del runtime
node "$ss\stage-selected.mjs" "$pub\selection.json" $src "$pub\stage" --apply; Paso 4

# 5. Publicar al runtime (respaldo + journal + read-back por archivo)
node "$ss\publish-selected.mjs" "$pub\selection.json" "$pub\stage" $rt "$pub\tx" $src --apply; Paso 5
"publicación $id terminada"
```

**Cómo se ve cuando sale bien:**

| Paso | Salida esperada |
|---|---|
| 2 | `N tracked runtime files selected` |
| 3 | `N selected files verified; no stage written` |
| 4 | termina sin error |
| 5 | `N selected files published; K live edits kept; rollback transaction retained`, o `N selected files already published` si no había nada nuevo |

Cada `SKIPPED live-edit <ruta>` es un archivo que alguien editó en vivo después
de la última publicación, casi siempre un agente mejorando su propia
`workshop-skill`. **No se pisó.** En la primera publicación, sin registro
previo, no hay skips: lo que difiera se reemplaza con respaldo en `$pub\tx`.

### Conciliar una edición viva

El script no tiene opción de «aceptar lo de `main`»: adopta un archivo solo si
el vivo ya es igual a lo que se publica, y salta el que difiere del último
instalado. Se concilia así, sin perder la edición:

1. **Guardarla en el repo.** Leer el archivo vivo byte a byte (exec de solo
   lectura, en base64 y comprobando el tamaño), revisar su diff contra `main`
   y llevarlo a un PR. Si una prueba exige copias idénticas en varios agentes
   (p. ej. `test-browser-profile-flag`), se replica en todas.
2. **Mergear y publicar.** Si `main` quedó igual al vivo, el archivo se adopta
   solo y no hay más que hacer.
3. **Si `main` trae algo encima del vivo** (vuelve a salir `SKIPPED`): comprobar
   que el vivo es exactamente la versión ya mergeada y apartarlo, sin borrarlo.
   Después se vuelve a publicar el mismo SHA:

   ```powershell
   $f = 'C:\Users\ehven\.openclaw\<ruta con \>'
   $esperado = '<sha256 del archivo en el commit que lo guardó>'
   if ((Get-FileHash $f -Algorithm SHA256).Hash.ToLower() -ne $esperado) { throw 'el vivo no es la versión guardada: no se aparta' }
   $d = 'C:\Users\ehven\.openclaw-publish\conciliados\' + (Get-Date -Format 'yyyyMMdd-HHmmss')
   New-Item -ItemType Directory -Force $d | Out-Null
   Move-Item $f $d
   ```

   Sin archivo vivo, el paso 5 lo instala con respaldo y la salida queda en
   `0 live edits kept`.

Con registro previo, el script nunca pisa un vivo que no está guardado en el repo. **Sin registro** (primera publicación de ese archivo, o tras un `--rollback` que lo borró del registro) sí lo reemplaza, y el respaldo queda solo en `$pub\tx`: antes de publicar un archivo así, compara el vivo con `main`.

**Guarda `$id`**: el rollback lo necesita.

## Desde la Mac

El harness no deja que un agente escriba en el host remoto. El operador corre
el bloque en el host, o lo registra como job de un solo uso y lo dispara él:

```bash
# publicar.ps1 = el bloque de arriba, guardado en la Mac
ARGV=$(python3 -c "import json;print(json.dumps(['powershell','-NoProfile','-Command',open('publicar.ps1').read()]))")
id=$(~/.openclaw/bin/openclaw cron add --name publicar-runtime --at 60m --command-argv "$ARGV" --json | python3 -c "import json,sys;r=sys.stdin.read();print(json.loads(r[r.find('{'):])['id'])")
~/.openclaw/bin/openclaw cron run "$id" --wait --wait-timeout 20m
~/.openclaw/bin/openclaw cron runs "$id" --limit 1     # status ok + la salida del paso 5
~/.openclaw/bin/openclaw cron rm "$id"                 # solo después de leer el resultado final
```

## Revertir

Con la misma carpeta de la publicación. No recibe fuente ni instala nada
staged: restaura los bytes previos y el registro.

```powershell
$pub = 'C:\Users\ehven\.openclaw-publish\<id>'
node 'C:\Users\ehven\src\goncloud-openclaw\scripts\sync-seguro\publish-selected.mjs' "$pub\selection.json" "$pub\stage" 'C:\Users\ehven\.openclaw' "$pub\tx" --rollback
```

Salida esperada: `selected publication rolled back`. Si un archivo cambió en
vivo después de publicar, el rollback se niega antes de tocar nada.

Si la publicación se cortó a la mitad, **se reintenta el mismo bloque con el
mismo `$id`**: lo publicado se salta y lo pendiente se completa. Con una carpeta
nueva mientras la anterior quedó a medias aborta con `prior transaction pending`.
Se revierte o se termina la anterior primero.

## Activar plugins

Antes de la separación del runtime, la config viva cargaba los dos plugins
publicados (`C:\Users\ehven\.openclaw-old-20260922\openclaw.json`):

```json5
{ plugins: {
    load: { paths: ["C:\\Users\\ehven\\.openclaw\\summa-gate", "C:\\Users\\ehven\\.openclaw\\tablero-runbook"] },
    entries: { "summa-gate": { enabled: true }, "tablero-runbook": { enabled: true } },
} }
```

Verificado el 2026-09-24: ambos plugins están cargados y habilitados. Al cambiar su código, reinicia el gateway para cargarlo. Publicar archivos de un plugin nuevo no lo habilita.
Restaurarlos es un `config.patch` por RPC (`openclaw gateway call config.patch`,
no `openclaw config patch`, que escribe la config de la Mac) y **exige
reiniciar el gateway**. El reinicio espera a que terminen las corridas en curso
y puede tardar varios minutos. Mientras tanto se caen el túnel de la Mac, la
app del iPhone y Telegram. Confirmar después con `config.get` (comparar
`hash`) y con el log `gateway http server listening (… plugins: …)`.

## Fuera de este camino

- **`workspace`, `workspace-operaciones`, `workspace-ingenieria`**: son
  memoria viva de los agentes, no se publican: se **respaldan** del runtime a
  la rama `respaldo/runtime` de cada repo `goncloud-workspace-*`, una vez al
  día desde la Mac (`scripts/mac/respaldo-workspaces.sh`, instalación en
  `scripts/mac/ai.goncloud.respaldo-workspaces.plist`). El respaldo solo lee
  el runtime y nunca empuja a `master`.
- **Watchdog**: `gateway-watchdog.ps1` se publica, pero la tarea programada
  `OpenClaw Gateway Watchdog` está deshabilitada. Publicar no la enciende.
