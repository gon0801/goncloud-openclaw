# Publicar `main` al runtime Windows (sync seguro U1)

Cómo llega lo mergeado en `gon0801/goncloud-openclaw` al gateway Windows desde
la separación del runtime del 22 de septiembre de 2026
(`docs/spec/00-project-spec.md`, «Propiedad del runtime Windows»). **Mergear a
`main` ya no despliega**: el sync de cada 2 h (`scripts/sync-repos.ps1`, tarea
`GoncloudRepoSync`) está deshabilitado y `C:\Users\ehven\.openclaw` ya no es un
clon git. El único camino es el pipeline de `scripts/sync-seguro/`, que se
corre a mano y solo con autorización del dueño.

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
   después de la autorización, lo nuevo también necesita la suya.
2. Ventana: `~/.openclaw/bin/openclaw cron list` sin ningún cron con `Next`
   en los próximos 15 minutos.
3. Autorización del dueño para esta publicación, escrita en el PR o en el chat.

## Publicar (PowerShell en el host Windows)

Todo el bloque se corre de una vez. Se detiene en el primer error y no toca el
runtime hasta el paso 5.

```powershell
$ErrorActionPreference = 'Stop'
$sha = '<SHA completo autorizado>'
$src = 'C:\Users\ehven\src\goncloud-openclaw'
$rt  = 'C:\Users\ehven\.openclaw'
$id  = Get-Date -Format 'yyyyMMdd-HHmmss'
$pub = "C:\Users\ehven\.openclaw-publish\$id"
$ss  = "$src\scripts\sync-seguro"
function Paso($n) { if ($LASTEXITCODE -ne 0) { throw "paso $n salió con $LASTEXITCODE" } }

# 1. Poner la fuente exactamente en el SHA autorizado (solo fast-forward de main)
if ((git -C $src rev-parse --abbrev-ref HEAD) -ne 'main') { throw 'la fuente no está en main' }
if (git -C $src status --porcelain) { throw 'fuente con cambios sin commitear' }
git -C $src fetch origin main; Paso 1
if ((git -C $src rev-parse origin/main) -ne $sha) { throw 'origin/main no es el SHA autorizado: main avanzó o el SHA está mal' }
git -C $src merge --ff-only $sha; Paso 1
if ((git -C $src rev-parse HEAD) -ne $sha) { throw 'la fuente no quedó en el SHA autorizado' }
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
de la última publicación. **No se pisó.** Se concilia a mano: se lleva la
edición a un PR o se acepta lo de `main` publicando otra vez después de
conciliar. En la primera publicación, sin registro previo, no hay skips: lo que
difiera se reemplaza con respaldo en `$pub\tx`.

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

## Activar plugins (aparte, con su propia autorización)

Antes de la separación del runtime, la config viva cargaba los dos plugins
publicados (`C:\Users\ehven\.openclaw-old-20260922\openclaw.json`):

```json5
{ plugins: {
    load: { paths: ["C:\\Users\\ehven\\.openclaw\\summa-gate", "C:\\Users\\ehven\\.openclaw\\tablero-runbook"] },
    entries: { "summa-gate": { enabled: true }, "tablero-runbook": { enabled: true } },
} }
```

Hoy la config viva no los tiene: publicar sus archivos no los enciende.
Restaurarlos es un `config.patch` por RPC (`openclaw gateway call config.patch`,
no `openclaw config patch`, que escribe la config de la Mac) y **exige
reiniciar el gateway**. El reinicio espera a que terminen las corridas en curso
y puede tardar varios minutos. Mientras tanto se caen el túnel de la Mac, la
app del iPhone y Telegram. Confirmar después con `config.get` (comparar
`hash`) y con el log `gateway http server listening (… plugins: …)`.

## Fuera de este camino

- **`workspace`, `workspace-operaciones`, `workspace-ingenieria`**: en el
  runtime ya no son clones git y la allowlist no los cubre. No hay camino
  documentado para actualizarlos; hace falta una decisión.
- **Watchdog**: `gateway-watchdog.ps1` se publica, pero la tarea programada
  `OpenClaw Gateway Watchdog` está deshabilitada. Publicar no la enciende.
