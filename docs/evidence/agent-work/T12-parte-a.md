# T12 parte A: R f1c5f34 instalado en la Mac Mini

El 2026-10-10 a las 05:13Z, David corrió el script de la sección Script (`t12-parte-a.sh`) desde la Mac de desarrollo; el script actúa en la Mini por ssh. Hace los pasos 0.4, 0.5 y 1.1 a 1.6 de `T12-runbook.md`, con un cambio: detiene el gateway **antes** de la foto, para que ninguna escritura quede entre la foto y el corte. Si algo falla después de detenerlo, vuelve solo a la foto y al 2026.9.7 público.

## Resultado

- El gateway estuvo fuera 36 s: se detuvo a las 05:13:56 y respondió `health` a las 05:14:32.
- Instalado: `OpenClaw 2026.9.7 (f1c5f34)`, y `build-info.json` con `commit` `f1c5f34ae8f91652412188349c296b3c1a882701`. Los sha256 de los dos `.tgz` coinciden con `artifact-manifest.json`.
- El estado migró del esquema 19 al 27. `managedTasks` no está en la config, así que la admisión de encargos sigue cerrada.
- Siguen habilitados los mismos 30 crons de antes.
- Foto en la Mini: `~/.openclaw/respaldos/pre-f1c5f34-20261009-2213`, con 24 archivos (473 MB) y la base en `19 ok`.
- npm no corrió los scripts de instalación de `koffi`, `protobufjs`, `esbuild` y `@google/genai`, porque `--allow-scripts` solo nombra al paquete raíz. El gateway arrancó y cargó sus plugins. Qué cambia sin esos scripts queda en `followups.md`.

## Resultados previos (plan, casilla 3 de T12)

En la ruta nativa no hay resultados: la admisión nunca se abrió en vivo. Los resultados de los loops viejos son archivos `LISTO-*` y `VEREDICTO-*` en `~/.local/state/<loop>/` de la Mac, y la instalación no los toca. El 2026-10-10 había 13 carpetas de loop con esos archivos:
- **Consumidos.** De loops cerrados: `cli-eventos-loop`, `orbit-fase-d`, `u3-loop`, `u3a-cierre` y `u3a-loop`. También `encargos-loop`, donde cada VEREDICTO ya se aplicó, hasta `VEREDICTO-B5-cierre-r2`.
- **Pendientes de su propio loop.** `bids-02-loop`, `jev-ads-01-loop`, `jev-ads-02-loop`, `revisor-correcciones-loop` y `revisor-loop`. Sus vigías y sus ventanas siguen igual.
- **Antiguos.** `acos-evidencia` (pausado desde el 2026-10-03) y `claw-avisos`.

No se reenvió ninguno.

## Log

```
== 05:13:54 0. Revisar antes de tocar nada
OpenClaw 2026.9.7 (c074824)
crons habilitados:       30
gateway pid 793
== 05:13:56 1.2 Detener el gateway
detenido
== 05:13:59 1.1 Foto completa (con el gateway detenido, sin escrituras en vuelo)
foto /Users/gon/.openclaw/respaldos/pre-f1c5f34-20261009-2213: 19 ok , 24 archivos, 473M
== 05:14:00 1.3 Instalar los dos paquetes juntos
npm warn allow-scripts   koffi@3.3.1 (install: node ./cnoke.cjs -P . -D src/koffi --prebuild --release)
npm warn allow-scripts   protobufjs@7.6.6 (postinstall: node scripts/postinstall)
npm warn allow-scripts   protobufjs@7.6.6 (postinstall: node scripts/postinstall)
npm warn allow-scripts
npm warn allow-scripts Run `npm install -g --allow-scripts=@google/genai,@google/genai,esbuild,koffi,protobufjs,protobufjs` to allow these scripts once, or `npm config set allow-scripts=@google/genai,@google/genai,esbuild,koffi,protobufjs,protobufjs --location=user` to allow them for all global installs.
OpenClaw 2026.9.7 (f1c5f34)
== 05:14:15 1.4 Arrancar (migra el estado 19 -> 27)
health ok
== 05:14:32 1.5 y 1.6 Comprobar
{
  "version": "2026.9.7",
  "commit": "f1c5f34ae8f91652412188349c296b3c1a882701",
  "builtAt": "2026-10-10T01:14:28.667Z",
  "buildId": "2026.9.7-release-f1c5f34ae8f9-2026-10-10T01-14-28.667Z"
}

esquema: 27
managedTasks: null
crons habilitados: los mismos       30
health: {
  "ok": true,
  "ts": 1791609272670,
  "durationMs": 18,
  "plugins": {
    "loaded": [
      "anthropic",
      "bonjour",
      "browser",
      "canvas",
      "codex",
      "cua-computer",
      "device-pair",
      "file-transfer",
      "geolocation",
      "github",
      "linux-node",
      "memory-core",
      "ollama",
      "openai",
      "opencode-go",
      "tablero-runbook",

PARTE A OK: R f1c5f34 instalado con la admisión cerrada. Foto: /Users/gon/.openclaw/respaldos/pre-f1c5f34-20261009-2213
```

## Script

Va en este documento porque, después del par de la matriz, la guarda de `test_agent_work_acceptance.py` solo deja cambiar documentos de evidencia.

```bash
#!/bin/bash
# T12 parte A (docs/evidence/agent-work/T12-runbook.md): instala R f1c5f34 en la Mac Mini con la admisión de
# encargos cerrada. Corre en la Mac de desarrollo y ejecuta todo en la Mini por ssh. Si algo falla después de
# detener el gateway, vuelve solo a la foto y al 2026.9.7 público. Salida: PARTE A OK, PARO (nada tocado) o REVERSA.
set -uo pipefail
H=gon@100.73.187.5
D=~/.local/state/encargos-loop/artifacts/T12
LOG=$D/parte-a-$(date -u +%Y%m%dT%H%M%SZ).log
mkdir -p "$D"
ssh -o ConnectTimeout=10 "$H" 'bash -s' <<'REMOTO' 2>&1 | tee "$LOG"
set -uo pipefail
OC=~/.openclaw
export PATH=$OC/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin
BIN=$OC/bin/openclaw
NPM=$OC/tools/node/bin/npm
LABEL=ai.openclaw.gateway
DOM=gui/$(id -u)
PLIST=~/Library/LaunchAgents/$LABEL.plist
SHA_R=76c0883e2a8f6206ed63dc78b291effbfa6946cf9d4bcc646ae9b88365982e2c
SHA_AI=0512fd870a86f40ea06f13931ef36a9ca9af07286d378fb1e717453ba6ffbcc8
F=$OC/respaldos/pre-f1c5f34-$(date +%Y%m%d-%H%M)

paso() { echo "== $(date -u +%T) $*"; }
paro() { echo "PARO: $* (no se tocó nada)"; exit 1; }
acotado() { perl -e 'alarm shift; exec @ARGV' "$@"; }
gw_pid() { launchctl print "$DOM/$LABEL" 2>/dev/null | awk '$1 == "pid" {print $3}'; }
crons_on() { acotado 60 "$BIN" cron list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); jobs = d.get("jobs", d) if isinstance(d, dict) else d
print(" ".join(sorted(j["id"] for j in jobs if j.get("enabled"))))'; }
running() { acotado 60 "$BIN" cron list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); jobs = d.get("jobs", d) if isinstance(d, dict) else d
print(sum(1 for j in jobs if (j.get("state") or {}).get("runningAtMs")))'; }

detener() {
  local pid; pid=$(gw_pid)
  launchctl bootout "$DOM/$LABEL" 2>&1 || true
  for _ in $(seq 60); do
    [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null && break
    sleep 1
  done
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "no salió en 60 s: SIGKILL a $pid"; kill -9 "$pid"; sleep 2; fi
  for _ in $(seq 30); do lsof -nP -iTCP:18789 -sTCP:LISTEN >/dev/null 2>&1 || return 0; sleep 1; done
  echo "el puerto 18789 sigue ocupado:"; lsof -nP -iTCP:18789 -sTCP:LISTEN; return 1
}

arrancar() {
  launchctl bootstrap "$DOM" "$PLIST" 2>&1 || true
  for _ in $(seq 60); do
    acotado 20 "$BIN" health --json > /tmp/t12-health.json 2>/dev/null && return 0
    sleep 5
  done
  return 1
}

reversa() {
  paso "REVERSA: $*"
  detener || true
  cp -p "$F/openclaw.sqlite" "$OC/state/openclaw.sqlite"
  rm -f "$OC/state/openclaw.sqlite-wal" "$OC/state/openclaw.sqlite-shm"
  for a in "$F"/agent-*.sqlite; do
    id=${a##*/agent-}; id=${id%.sqlite}; d=$OC/agents/$id/agent
    cp -p "$a" "$d/openclaw-agent.sqlite"; rm -f "$d/openclaw-agent.sqlite-wal" "$d/openclaw-agent.sqlite-shm"
  done
  cp -p "$F/openclaw.json" "$OC/openclaw.json"
  "$NPM" install -g --allow-scripts=openclaw openclaw@2026.9.7 2>&1 | tail -3
  "$BIN" --version
  if arrancar; then echo "REVERSA OK: el gateway volvió a 2026.9.7 (c074824) con la foto $F"; else echo "REVERSA INCOMPLETA: el gateway no responde; la foto está en $F"; fi
  exit 2
}

paso "0. Revisar antes de tocar nada"
v=$("$BIN" --version); echo "$v"; [[ "$v" == *"(c074824)"* ]] || paro "la versión viva es $v, no c074824"
[ -f "$PLIST" ] || paro "no existe $PLIST"
[ "$(shasum -a 256 /tmp/openclaw-2026.9.7.tgz | cut -d' ' -f1)" = "$SHA_R" ] || paro "hash de /tmp/openclaw-2026.9.7.tgz"
[ "$(shasum -a 256 /tmp/openclaw-ai-2026.9.7.tgz | cut -d' ' -f1)" = "$SHA_AI" ] || paro "hash de /tmp/openclaw-ai-2026.9.7.tgz"
n=$(running); [ "$n" = "0" ] || paro "hay $n crons corriendo; repetir en unos minutos"
ANTES=$(crons_on); [ -n "$ANTES" ] || paro "no pude leer los crons habilitados"
echo "crons habilitados: $(wc -w <<< "$ANTES")"
echo "gateway pid $(gw_pid)"

paso "1.2 Detener el gateway"
detener || paro "el gateway no se detuvo"
echo "detenido"

paso "1.1 Foto completa (con el gateway detenido, sin escrituras en vuelo)"
mkdir -p "$F" && chmod 700 "$OC/respaldos" "$F"
sqlite3 "$OC/state/openclaw.sqlite" ".backup $F/openclaw.sqlite" || { arrancar; paro "falló la foto de openclaw.sqlite"; }
for f in "$OC"/agents/*/agent/openclaw-agent.sqlite; do
  id=$(basename "$(dirname "$(dirname "$f")")")
  sqlite3 "$f" ".backup $F/agent-$id.sqlite" || { arrancar; paro "falló la foto de $id"; }
done
cp -p "$OC/openclaw.json" "$F/" && chmod 600 "$F"/*
chk=$(sqlite3 "$F/openclaw.sqlite" "PRAGMA user_version; PRAGMA quick_check;" | tr '\n' ' ')
echo "foto $F: $chk, $(ls "$F" | wc -l | tr -d ' ') archivos, $(du -sh "$F" | cut -f1)"
[ "$chk" = "19 ok " ] || { arrancar; paro "la foto no es 19/ok: $chk"; }

paso "1.3 Instalar los dos paquetes juntos"
"$NPM" install -g --allow-scripts=/tmp/openclaw-2026.9.7.tgz /tmp/openclaw-ai-2026.9.7.tgz /tmp/openclaw-2026.9.7.tgz 2>&1 | tail -5
v=$("$BIN" --version); echo "$v"; [[ "$v" == *"(f1c5f34)"* ]] || reversa "la versión instalada es $v"

paso "1.4 Arrancar (migra el estado 19 -> 27)"
arrancar || reversa "el gateway no respondió health ok en 5 min"
echo "health ok"

paso "1.5 y 1.6 Comprobar"
cat "$OC/tools/node-v24.19.0/lib/node_modules/openclaw/dist/build-info.json"; echo
grep -q f1c5f34 "$OC/tools/node-v24.19.0/lib/node_modules/openclaw/dist/build-info.json" || reversa "build-info no es f1c5f34"
echo "esquema: $(sqlite3 "file:$OC/state/openclaw.sqlite?mode=ro" 'PRAGMA user_version;')"
acotado 60 "$BIN" gateway call config.get --params '{}' --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin); c = d.get("config", d)
m = c.get("managedTasks") if isinstance(c, dict) else None
print("managedTasks:", json.dumps(m))
sys.exit(0 if not m or not m.get("enabled") else 1)' || echo "AVISO: managedTasks habilitado; congelarlo (runbook 1.5)"
DESPUES=$(crons_on)
[ "$ANTES" = "$DESPUES" ] && echo "crons habilitados: los mismos $(wc -w <<< "$DESPUES")" || echo "AVISO: cambiaron los crons habilitados"
echo "health: $(head -c 400 /tmp/t12-health.json)"
echo "PARTE A OK: R f1c5f34 instalado con la admisión cerrada. Foto: $F"
REMOTO
echo "log: $LOG"
```
