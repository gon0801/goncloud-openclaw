# Comandos de despliegue del runtime nativo (T11 :296)

Todos los comandos de esta página se ensayaron el 2026-10-09 en la Mac de desarrollo, que es macOS arm64 como la Mac Mini del gateway vivo. Usan el Node que trae OpenClaw (`~/.openclaw/tools/node`, v24.19.0). Nada de esto se corrió contra el gateway vivo: el ensayo usa prefijos y HOME temporales. La autorización y la ventana de T12 son de David.

El artefacto y sus hashes están en `artifact-manifest.json`, y `scripts/agent-work/artifact.py verify` los comprueba. El runtime es la rama `feat/agent-work-integration` de R en `818f0fdacfb090c5ea51d29db9744ac90e977fcb`, que nunca se sube a ningún remoto. El que corre hoy en la Mini es el 2026.9.7 público, build `c074824a27c9`.

## Dónde vive OpenClaw en el host

El instalador de OpenClaw pone el paquete global dentro de su propio Node. El lanzador es `~/.openclaw/bin/openclaw`, que ejecuta `~/.openclaw/tools/node/bin/node ~/.openclaw/tools/node-v24.19.0/lib/node_modules/openclaw/dist/entry.js`. Se midió en esta Mac. En la Mini, `health` reporta `childRuntime.execPath=/Users/gon/.openclaw/tools/node-v24.19.0/bin/node`, la misma estructura. Por eso la instalación en el host es un `npm install -g` con ese npm, sin `--prefix`.

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
| 1. Foto | `F=~/.openclaw/respaldos/pre-<sha7>-$(date +%Y%m%d-%H%M); mkdir -p "$F"; sqlite3 ~/.openclaw/state/openclaw.sqlite ".backup $F/openclaw.sqlite"; for f in ~/.openclaw/agents/*/agent/openclaw-agent.sqlite; do sqlite3 "$f" ".backup $F/agent-$(basename "$(dirname "$(dirname "$f")")").sqlite"; done` | `sqlite3 "$F/openclaw.sqlite" 'PRAGMA user_version; PRAGMA quick_check;'` imprime `19` y `ok` | 1 min (medido el 2026-10-09 contra la Mini viva, por ssh: 564 MB en total, sin detener el gateway) | Sin foto válida no se instala. |
| 2. Instalar | `~/.openclaw/tools/node/bin/npm install -g --allow-scripts=<dir>/openclaw-2026.9.7.tgz <dir>/openclaw-ai-2026.9.7.tgz <dir>/openclaw-2026.9.7.tgz` | `added … packages`; `npm warn allow-scripts` no lista `openclaw` | 2 min (medido: 15 s en un prefijo vacío) | La versión anterior queda reemplazada a medias: sigue la recuperación de abajo. |
| 3. Humo | `~/.openclaw/bin/openclaw --version` | `OpenClaw 2026.9.7 (818f0fd)` | 5 s | Recuperación. |

Los dos `.tgz` (`@openclaw/ai` y `openclaw`) van juntos en la misma instalación. Instalado solo, el paquete `openclaw` baja de npm el `@openclaw/ai` público, y el gateway truena al cargar con `does not provide an export named 'responsesDispatchHook'` (medido; está en `smoke.log` de la carpeta del paquete). `--allow-scripts` va con la ruta del `.tgz` raíz, porque npm compara contra la ruta y no contra el nombre `openclaw`. Instalar encima de un `openclaw@2026.9.7` público ya instalado deja la versión de R y quita el `@openclaw/ai` anidado de upstream (medido).

El arranque del gateway con la base migrada (19 → 27) y la adopción se ensayan en T11-b, sobre una copia aislada del estado de la Mini.

## Recuperar

R migra la base de estado de la versión 19 a la 27, y el binario 2026.9.7 público rechaza una base más nueva (`openclaw-database-preflight.ts:239,242` en `c074824a27`). Por eso recuperar no es solo reinstalar: también hay que volver a la foto.

| Paso | Comando | Salida esperada | Duración máxima | Ante fallo |
|---|---|---|---|---|
| 1. Binario anterior | `~/.openclaw/tools/node/bin/npm install -g --allow-scripts=openclaw openclaw@2026.9.7` | `~/.openclaw/bin/openclaw --version` imprime `OpenClaw 2026.9.7 (c074824)` | 2 min (medido: 10 s en un prefijo vacío, con red) | Sin red, reinstala desde el `.tgz` público guardado (`npm pack openclaw@2026.9.7` en la preparación). |
| 2. Base | Con el gateway detenido: `cp "$F/openclaw.sqlite" ~/.openclaw/state/openclaw.sqlite`, borrar `openclaw.sqlite-wal` y `openclaw.sqlite-shm` viejos, y lo mismo para cada `agent-<id>.sqlite` | `PRAGMA user_version` = `19` y `quick_check` = `ok` (medido sobre la copia: 1 s) | 5 min | Si el binario anterior no abre la base, conserva la versión nueva con la admisión congelada (spec y plan `:300`). |

Lo que pasó entre la foto y la recuperación (sesiones, resultados) se pierde de la base restaurada. Por eso la ventana de instalación es sin trabajo en vuelo (T12 `:309`), y la captura de resultados queda activa durante todo el cambio. El ensayo completo de la reversa, con el gateway arrancado sobre la base restaurada y las fallas de la propia reversa, es T11-c (`:300` y `:301`).

## Evidencia

Las salidas de cada comando están en `~/.local/state/encargos-loop/artifacts/T11-a/`: `paquete/corrida-limpia.log`, `paquete/install.log`, `paquete/smoke.log`, `paquete/actualizacion-sobre-upstream.log`, `recuperacion-binario.log` y `foto-restauracion.log`. El recibo es `T11.md`.
