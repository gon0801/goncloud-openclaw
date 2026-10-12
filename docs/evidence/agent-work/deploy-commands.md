# Comandos de despliegue del runtime nativo (T11 :296)

Todos los comandos de esta página se ensayaron el 2026-10-09 en la Mac de desarrollo, que es macOS arm64 como la Mac Mini del gateway vivo. Usan el Node que trae OpenClaw (`~/.openclaw/tools/node`, v24.19.0). Nada de esto se corrió contra el gateway vivo: el ensayo usa prefijos y HOME temporales. La autorización y la ventana de T12 son de David.

El artefacto y sus hashes están en `artifact-manifest.json`, y `scripts/agent-work/artifact.py verify` los comprueba. El runtime es la rama `feat/agent-work-integration` de R en `f1c5f34ae8f91652412188349c296b3c1a882701`, que nunca se sube a ningún remoto. Las duraciones de abajo se midieron con el build de `818f0fd`. `f1c5f34` solo agrega el evento `provider.payload.measured`, y sobre él los e2e del corte y de la reversa dieron OK (`B5-logs.md`). El que corre hoy en la Mini es el 2026.9.7 público, build `c074824a27c9`.

## Dónde vive OpenClaw en el host

El instalador de OpenClaw pone el paquete global dentro de su propio Node. El lanzador es `~/.openclaw/bin/openclaw`, que ejecuta `~/.openclaw/tools/node/bin/node ~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist/entry.js`. Se midió en esta Mac. En la Mini, `health` reporta `childRuntime.execPath=/Users/gon/.openclaw/tools/node-v24.19.0/bin/node`, la misma estructura (`T11-a-mini-health.log`). Por eso la instalación en el host es un `npm install -g` con ese npm, sin `--prefix`.

## Construir y empaquetar (una vez por SHA, en la máquina de build)

| Paso | Comando | Salida esperada | Duración máxima | Ante fallo |
|---|---|---|---|---|
| 1 | `bash scripts/agent-work/runtime/empaquetar-r.sh /Users/dn/dev/openclaw-agent-work-integration <sha> "$(mktemp -d)"` | termina con `== smoke: exit=0` y `OpenClaw 2026.9.7 (<sha7>)` | 10 min (medido: 435 s; el build tarda 382 s) | No sigas. Conserva el worktree que imprime y su log. Un `update:compat:check` que falla está esquivado a propósito (abajo); cualquier otra falla es real. |
| 2 | Copiar los cuatro `.tgz` y `package-bundle.json` de la salida a la carpeta `packageDir` del manifiesto, y escribir sus `sha256` e `integrity` en el manifiesto | — | 1 min | — |
| 3 | `python3 scripts/agent-work/artifact.py verify` | `artifact OK: openclaw 2026.9.7 from <sha>` | 5 s | Cada línea `artifact: …` nombra el paquete y la discrepancia (hash, commit del build, `entry.js`, versión de esquema). No instales un artefacto que no verifica. |

`empaquetar-r.sh` sigue el camino de release de upstream (`prepareNpmPackageBundle` de `scripts/npm-prepared-bundle.mjs`, con `pnpm pack --config.node-linker=hoisted`). Construye con `OPENCLAW_CONTROL_UI_RELEASE_BUILD=1` y se aparta de upstream en dos cosas:
- **No es GitHub Actions.** El bundle queda marcado `producer.local`, así que no es publicable.
- **Se salta `update:compat:check`.** Ese chequeo consulta los dist-tags de npm en vivo, y en un SHA congelado falla con `Update compatibility inventory is missing current npm release versions: 2026.9.9, 2026.10.1-beta.2`. No cambia el contenido del paquete.

Ni `pnpm pack` ni `npm pack` sirven solos. `pnpm pack` falla con `ERR_PNPM_BUNDLED_DEPENDENCIES_WITHOUT_HOISTED`. `npm pack` deja dependencias `workspace:*`, y luego `npm install` falla con `EUNSUPPORTEDPROTOCOL`.

## Instalar en el host

Antes de instalar, saca una foto consistente de la base de estado y de la de cada agente. La admisión debe estar congelada y la captura de resultados activa; eso lo hace `cutover.py`, que es T11-b.

| Paso | Comando | Salida esperada | Duración máxima | Ante fallo |
|---|---|---|---|---|
| 1. Foto | `F=~/.openclaw/respaldos/pre-<sha7>-$(date +%Y%m%d-%H%M); mkdir -p "$F"; sqlite3 ~/.openclaw/state/openclaw.sqlite ".backup $F/openclaw.sqlite"; for f in ~/.openclaw/agents/*/agent/openclaw-agent.sqlite; do sqlite3 "$f" ".backup $F/agent-$(basename "$(dirname "$(dirname "$f")")").sqlite"; done; cp ~/.openclaw/openclaw.json "$F/"` | `sqlite3 "$F/openclaw.sqlite" 'PRAGMA user_version; PRAGMA quick_check;'` imprime `19` y `ok` | 1 min (medido el 2026-10-09 contra la Mini viva, por ssh: 564 MB en total, sin detener el gateway; `T11-a-foto-mini.log`) | Sin foto válida no se instala. |
| 2. Instalar | `~/.openclaw/tools/node/bin/npm install -g --allow-scripts=<dir>/openclaw-2026.9.7.tgz <dir>/openclaw-ai-2026.9.7.tgz <dir>/openclaw-2026.9.7.tgz` | `added … packages`; `npm warn allow-scripts` no lista `openclaw` | 2 min (medido: 15 s en un prefijo vacío) | La versión anterior queda reemplazada a medias: sigue la recuperación de abajo. |
| 3. Humo | `~/.openclaw/bin/openclaw --version` | `OpenClaw 2026.9.7 (19c2ed1)`, el `sourceSha` de `artifact-manifest.json` | 5 s | Recuperación. |

Los dos `.tgz` (`@openclaw/ai` y `openclaw`) van juntos en la misma instalación. Instalado solo, el paquete `openclaw` baja de npm el `@openclaw/ai` público, y el gateway truena al cargar con `does not provide an export named 'responsesDispatchHook'` (medido; está en `smoke.log` de la carpeta del paquete). `--allow-scripts` va con la ruta del `.tgz` raíz, porque npm compara contra la ruta y no contra el nombre `openclaw`. Instalar encima de un `openclaw@2026.9.7` público ya instalado deja la versión de R y quita el `@openclaw/ai` anidado de upstream (medido).

El arranque del gateway con la base migrada (19 → 27) y la adopción se ensayan en T11-b, sobre una copia aislada del estado de la Mini.

## Recuperar

Lo midió el ensayo de T11-c sobre la copia de la Mini, con los dos binarios reales (`T11-c-*.log`):
- el 2026.9.7 público se niega a arrancar sobre la base migrada (`refused startup because 1 OpenClaw database schema(s) are newer than this build ... uses schema 27`);
- también rechaza la config del corte (`Unrecognized key: "managedTasks"`);
- con la base y la config de la foto, arranca (`[gateway] ready`).

Por eso recuperar es volver a la foto completa, que tiene que incluir `openclaw.json`. Pero la foto es de *antes* del corte, así que trae los crons viejos **habilitados**: restaurarla los reactivaría, y eso está prohibido (plan `:301`).

`cutover_live.rollback` hace la reversa en este orden. Cada paso deja su fase en el estado del corte y se retoma:

1. **Revisar la foto.** Tiene que existir, estar en la versión 19 con `quick_check ok` y traer un `openclaw.json` sin `managedTasks`. Si no, se niega **antes de detener nada**: congela la admisión y deja el candidato corriendo.
2. **Congelar la admisión** (`managedTasks.enabled=false`). El gateway se reinicia y la reversa lo espera.
3. **Detener el gateway, y restaurar las bases y la config de la foto.**
4. **Arrancar el binario anterior con el planificador de cron apagado** y volver a suspender los crons viejos de la entrada, con los ids que guardó el corte.
5. **Arrancar normal** y comprobar otra vez que siguen suspendidos.

Si el binario anterior no arranca, vuelve el candidato sobre la foto restaurada. Sin `managedTasks` en la config, la admisión queda congelada, y también se suspenden ahí los crons viejos. La reversa nunca toca los spools del host, así que los resultados pendientes se conservan.

| Paso en el host | Comando | Salida esperada | Duración máxima | Ante fallo |
|---|---|---|---|---|
| Binario anterior | `~/.openclaw/tools/node/bin/npm install -g --allow-scripts=openclaw openclaw@2026.9.7` | `~/.openclaw/bin/openclaw --version` imprime `OpenClaw 2026.9.7 (c074824)` | 2 min (medido: 10 s en un prefijo vacío, con red) | Sin red, desde el `.tgz` público guardado en la preparación. |
| Bases y config | Con el gateway detenido: copiar `$F/openclaw.sqlite` a `~/.openclaw/state/`, cada `agent-<id>.sqlite` a `~/.openclaw/agents/<id>/agent/openclaw-agent.sqlite` y `$F/openclaw.json` a `~/.openclaw/`, y borrar los `-wal` y `-shm` viejos | `PRAGMA user_version` = `19` y `quick_check` = `ok` | 5 min | La reversa se queda con el candidato congelado. |
| Arranque sin cron | `OPENCLAW_SKIP_CRON=1 ~/.openclaw/bin/openclaw gateway` en primer plano, y `openclaw gateway call cron.update` con `enabled: false` para cada cron viejo | `cron.list`: los crons viejos en `enabled: false` | 3 min | Si el binario no arranca, se vuelve al candidato congelado (paso de arriba). |

En el host vivo, los pasos de detener y arrancar el gateway dependen de cómo lo lanza la Mini (launchd). T12 los fija antes de la ventana, porque el ensayo los hace con `scripts/agent-work/runtime/ensayo_host.py`.

Lo que pasó entre la foto y la recuperación (sesiones, resultados en la base) se pierde. Por eso la ventana de instalación es sin trabajo en vuelo (T12 `:309`), y los resultados que el host capturó siguen en su spool.

### Revertir una sola entrada, con el binario nuevo corriendo

Si el binario nuevo funciona y lo que falla es una entrada adoptada, no hace falta la foto. `cutover_live.py revert` deshace el corte de esa entrada en el gateway vivo, en este orden:

1. **Cierra la admisión de la entrada.** Quita su adaptador de `managedTasks.hosts.<host>.adapters` con `config.patch`, `baseHash` y `replacePaths`. Si el host se queda sin adaptadores, lo quita, porque R exige al menos uno por host. Si no queda ningún adaptador en ningún host, pone `managedTasks.enabled=false`. El gateway se reinicia y `revert` lo espera.
2. **Rehabilita los crons viejos.** Solo los ids que el estado del corte guardó en `suspended`, que son los que el corte deshabilitó. Si alguno ya no existe en el gateway (por ejemplo, porque B.7 lo borró), se niega y lo nombra.
3. **No toca los spools del host**, así que los resultados capturados se conservan.

Cada paso deja su fase en `revert.phase` del estado (`start`, `frozen`, `done`), así que el mismo comando retoma donde se quedó. Al terminar, el estado queda con `owner: legacy` y la generación sube en uno. Si el estado muestra que la entrada nunca se transfirió (`owner: legacy` sin una reversa previa), se niega sin tocar nada.

| Paso | Comando | Salida esperada | Duración máxima | Ante fallo |
|---|---|---|---|---|
| Revertir la entrada | `python3 scripts/agent-work/cutover_live.py revert --state <estado> --wait-seconds 120` | `reverted; old crons re-enabled`, o `already reverted` si ya se hizo | 2 min (espera al menos 60 s el reinicio) | `cutover: …` nombra la causa. Correr el mismo comando otra vez retoma desde la fase guardada. |
| Congelar toda la admisión | `python3 scripts/agent-work/cutover_live.py freeze --wait-seconds 120` | `frozen` (`managedTasks.enabled=false`; no necesita `--state`) | 2 min | `cutover: admission did not freeze`: leer `config.get` y repetir. |

`freeze` cierra la admisión de todas las entradas a la vez y no rehabilita ningún cron. Sirve para parar de golpe. `revert` es la reversa completa de una sola entrada.

## Abrir alias de modelo en mac-local (B19)

Dos scripts de la Mac de desarrollo, en `~/.local/state/encargos-loop/artifacts/T12/`. Los dos corren desde el checkout del host, que tiene que traer B19, y no llevan secretos. Se ensayaron en la Mac contra una copia de la config con el CLI doble `scripts/tests/fixtures/agent-work/openclaw-config-double.py`, y el de las skills, además, con `ssh` y `scp` dobles sobre un HOME falso de la Mini. No se corrieron contra el gateway vivo ni contra la Mini.

| Paso | Comando | Salida esperada | Duración máxima | Ante fallo |
|---|---|---|---|---|
| Abrir los alias en R | `bash ~/.local/state/encargos-loop/artifacts/T12/t12-adapters-1.sh` | `ADAPTADORES OK` y la lista `adapters` de `mac-local` con `opencode` y los cuatro alias | 3 min (el gateway se reinicia unos 6 s) | `PARO: …` nombra la causa. Hasta el paso 3 no se escribió nada; después, correrlo otra vez retoma, porque un alias que ya está no se vuelve a escribir. |
| Publicar las skills de `main` | `bash ~/.local/state/encargos-loop/artifacts/T12/t12-skills-main-1.sh` | `SKILLS OK`, los dos sha256 iguales y `Sin reinicio` | 1 min | `PARO: …`. La copia anterior de `agent-dispatch` queda en `~/.openclaw/respaldos/skills-pre-b19-<fecha>/` de la Mini. |

Quitar un alias es lo contrario y sí necesita `replacePaths`: `config.patch` con `{"managedTasks": {"hosts": {"mac-local": {"adapters": [<los que quedan>]}}}}`, `baseHash` y `replacePaths: ["managedTasks.hosts.mac-local.adapters"]`, como `entry_close_patch` de `cutover_live.py`.

`t12-adapters-1.sh`:

```bash
#!/bin/bash
# B19: abre en R los alias de modelo de opencode de mac-local (managedTasks.hosts.mac-local.adapters).
# Corre en la Mac de desarrollo, desde el checkout del host, que ya debe traer B19. Solo agrega adaptadores
# a esa lista, con config.patch y baseHash, sin replacePaths: no toca deviceId, requesters, profile ni
# ninguna otra clave. El cambio de managedTasks reinicia el gateway (unos 6 s), y un turno en vuelo de
# cualquier agente se pierde: córrelo sin loops ni encargos en curso.
# Salidas: ADAPTADORES OK, o PARO con el motivo (sin cambios si paró antes del paso 4).
set -uo pipefail
G=${G:-$HOME/dev/wt/agent-work-host}
export OPENCLAW_BIN=${OPENCLAW_BIN:-$HOME/.openclaw-r/openclaw} LANG=en_US.UTF-8
LOG=${LOG:-$HOME/.local/state/encargos-loop/artifacts/T12/adapters-1-$(date -u +%Y%m%dT%H%M%SZ).log}
ALIASES=(opencode@opencode-go/deepseek-v4-pro opencode@opencode-go/kimi-k3 opencode@opencode-go/grok-4.7
         opencode@opencode-go/qwen3.8-max)
paso() { echo "== $(date -u +%T) $*"; }
paro() { echo "PARO: $*"; exit 1; }
add=(); for a in "${ALIASES[@]}"; do add+=(--add "$a"); done
{
paso "1. El checkout $G trae B19"
cd "$G" || paro "no existe $G"
python3 scripts/agent-work/host.py opencode-model "${ALIASES[0]}" >/dev/null \
  || paro "$G no trae B19: git -C $G fetch origin && git -C $G checkout --detach origin/main"

paso "2. Ningún cron corriendo"
"$OPENCLAW_BIN" gateway call cron.list --params '{}' --json | python3 -c '
import json, sys
running = [job["name"] for job in json.load(sys.stdin)["jobs"] if (job.get("state") or {}).get("runningAtMs")]
print("corriendo: " + (", ".join(running) or "ninguno"))
sys.exit(1 if running else 0)' || paro "hay crons corriendo; espera a que terminen"

paso "3. Vista previa (no escribe)"
python3 scripts/agent-work/cutover_live.py adapters --host mac-local "${add[@]}" --dry-run --wait-seconds 30 \
  || paro "la vista previa falló; no se tocó nada"

paso "4. Aplicar (el gateway se reinicia)"
python3 scripts/agent-work/cutover_live.py adapters --host mac-local "${add[@]}" --wait-seconds 120 \
  || paro "no se abrieron; correr el script otra vez retoma"

paso "5. Releer la config viva"
"$OPENCLAW_BIN" gateway call config.get --params '{}' --json | python3 -c '
import json, sys
managed = json.load(sys.stdin)["resolved"]["managedTasks"]
adapters = managed["hosts"]["mac-local"]["adapters"]
print(json.dumps({"enabled": managed.get("enabled"), "requesters": managed.get("requesters"), "adapters": adapters}))
sys.exit(0 if managed.get("enabled") and set(sys.argv[1:]) <= set(adapters) else 1)' "${ALIASES[@]}" \
  || paro "la config viva no trae los alias"
echo "ADAPTADORES OK"
} 2>&1 | tee "$LOG"
status=$?
echo "log: $LOG"
exit $status
```

`t12-skills-main-1.sh`:

```bash
#!/bin/bash
# B19: publica en la Mini las skills de main encargo-cli (nueva) y agent-dispatch (sin el puntero viejo a
# routing.py). Corre en la Mac de desarrollo, desde el checkout del host, que ya debe traer B19.
# No hace falta reiniciar el gateway. En R 605aef7 un watcher (chokidar) vigila workshop-skills
# (src/skills/runtime/refresh-source-roots.ts:48) y sube la versión del snapshot de skills; el turno
# siguiente de main la compara y rehace el catálogo (src/skills/runtime/session-snapshot.ts:79-116), y el
# cuerpo de SKILL.md se lee del disco al invocarla. La excepción es skills.load.watch=false (paso 6).
# Antes de pisar agent-dispatch guarda la copia de la Mini en ~/.openclaw/respaldos/skills-pre-b19-<fecha>/
# (fuera de workshop-skills) y muestra qué líneas solo tiene esa copia.
# Salidas: SKILLS OK, o PARO con el motivo.
set -uo pipefail
H=${H:-gon@100.73.187.5}
G=${G:-$HOME/dev/wt/agent-work-host}
export OPENCLAW_BIN=${OPENCLAW_BIN:-$HOME/.openclaw-r/openclaw} LANG=en_US.UTF-8
LOG=${LOG:-$HOME/.local/state/encargos-loop/artifacts/T12/skills-main-1-$(date -u +%Y%m%dT%H%M%SZ).log}
DEST=.openclaw/agents/main/agent/workshop-skills
SRC=agents/main/agent/workshop-skills
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP=.openclaw/respaldos/skills-pre-b19-$STAMP
paso() { echo "== $(date -u +%T) $*"; }
paro() { echo "PARO: $*"; exit 1; }
{
paso "1. El checkout $G trae B19"
cd "$G" || paro "no existe $G"
[ -f "$SRC/encargo-cli/SKILL.md" ] || paro "$G no trae B19: git -C $G fetch origin && git -C $G checkout --detach origin/main"

paso "2. Ninguna skill de otra raíz tapa a estas (R deja ganar a la última raíz por name)"
shadows=$(ssh -o ConnectTimeout=10 "$H" 'for d in ~/.openclaw/skills ~/.agents/skills ~/.openclaw/workspace/skills; do [ -d "$d" ] && grep -rlE "^name: (encargo-cli|agent-dispatch)$" "$d" --include=SKILL.md; done; true') \
  || paro "no se pudo leer la Mini"
[ -z "$shadows" ] || paro "estas skills taparían a las de main: $shadows"
echo "ninguna"

paso "3. Copia de respaldo de agent-dispatch en la Mini"
ssh -o ConnectTimeout=10 "$H" "mkdir -p $DEST/encargo-cli $BACKUP && cp -p $DEST/agent-dispatch/SKILL.md $BACKUP/agent-dispatch.SKILL.md" \
  || paro "no se pudo respaldar agent-dispatch en la Mini"
echo "respaldo en la Mini: ~/$BACKUP/agent-dispatch.SKILL.md"
scp -q "$H:$BACKUP/agent-dispatch.SKILL.md" "${LOG%.log}.agent-dispatch.mini" || paro "no se pudo traer la copia de la Mini"
echo "líneas que solo tiene la copia de la Mini (se pierden al publicar; quedan en el respaldo):"
diff "${LOG%.log}.agent-dispatch.mini" "$SRC/agent-dispatch/SKILL.md" | grep '^<' | head -40
echo "($(diff "${LOG%.log}.agent-dispatch.mini" "$SRC/agent-dispatch/SKILL.md" | grep -c '^<') líneas)"

paso "4. Copiar las dos skills"
for s in encargo-cli agent-dispatch; do
  scp -q "$SRC/$s/SKILL.md" "$H:$DEST/$s/SKILL.md" || paro "no se pudo copiar $s"
done

paso "5. sha256 en los dos lados"
for s in encargo-cli agent-dispatch; do
  a=$(shasum -a 256 "$SRC/$s/SKILL.md" | cut -d' ' -f1)
  b=$(ssh "$H" "shasum -a 256 $DEST/$s/SKILL.md" | cut -d' ' -f1)
  echo "$s mac=$a mini=$b"
  [ "$a" = "$b" ] || paro "$s difiere en la Mini"
done

paso "6. ¿Hace falta reiniciar?"
watch=$("$OPENCLAW_BIN" gateway call config.get --params '{}' --json | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["resolved"].get("skills", {}).get("load", {}).get("watch")))') \
  || paro "no se pudo leer la config (las skills ya están copiadas)"
echo "skills.load.watch = $watch"
if [ "$watch" = "false" ]; then
  echo "REINICIO: con el watcher apagado, main no ve el cambio hasta reiniciar el gateway"
else
  echo "Sin reinicio: el siguiente turno de main ve encargo-cli"
fi
echo "SKILLS OK"
} 2>&1 | tee "$LOG"
status=$?
echo "log: $LOG"
exit $status
```

## Evidencia

Las salidas de cada comando están en `~/.local/state/encargos-loop/artifacts/T11-a/`: `paquete/corrida-limpia.log`, `paquete/install.log`, `paquete/smoke.log`, `paquete/actualizacion-sobre-upstream.log`, `recuperacion-binario.log` y `foto-restauracion.log`. Los de la reversa son `T11-c-*.log`. El recibo es `T11.md`.
