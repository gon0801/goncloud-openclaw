#!/bin/bash
# Prueba focalizada de openclaw-pasarela (19.0-r2). La pasarela es el unico
# punto que puede hablar con el gateway real: esta prueba fija su frontera.
#   1) system event a agent:main:main            -> NEGADO (rc!=0, sin tocar el real)
#   2) system event a agent:main:vigia-mac       -> NEGADO
#   3) system event a agent:main:sim9-arnes19-x  -> sale REAL (el binario real recibe argv intacto)
#   4) system event con clave forastera          -> NEGADO
#   5) message send                              -> doblado (fixture messageId, sin tocar el real)
#   6) cron list                                 -> doblado (fixture del canal arnes)
#   7) toda llamada deja sello monotono en el log
# Uso: bash test-pasarela.sh
set -u
PASARELA="$(cd "$(dirname "$0")" && pwd)/openclaw-pasarela"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
LOG="$T/doble.jsonl"
REAL="$T/real-falso"
REAL_SENAL="$T/llamado-real"
export REAL_SENAL
# El doble del binario real deja constancia del argv EXACTO que recibio (F2):
# su primera linea debe empezar en system|cron|message, sin nada de la
# pasarela al frente.
printf '#!/bin/bash\nprintf "real-llamado\\n" >> "$REAL_SENAL"\nprintf "%%s\\n" "$@" >> "$REAL_SENAL"\n' > "$REAL"
chmod +x "$REAL"
fallas=0
correr() { # $1 descripcion, $2 espera-real (si|no), resto argv
  local desc=$1 espera=$2; shift 2
  rm -f "$REAL_SENAL"
  : > "$LOG"
  DOBLE_LOG="$LOG" OPENCLAW_REAL_BIN="$REAL" bash "$PASARELA" "$@" >"$T/salida" 2>"$T/error"
  local rc=$?
  if [ "$espera" = si ]; then
    if [ "$rc" -eq 0 ] && grep -q real-llamado "$REAL_SENAL" 2>/dev/null && grep -q '"mono_ns"' "$LOG"; then
      case "$(sed -n 2p "$REAL_SENAL" 2>/dev/null)" in
        system|cron|message) echo "ok: $desc";;
        *) echo "FALLA: $desc (argv del real empieza en '$(sed -n 2p "$REAL_SENAL" 2>/dev/null)')"; fallas=$((fallas+1));;
      esac
    else
      echo "FALLA: $desc (rc=$rc)"; fallas=$((fallas+1))
    fi
  else
    if [ "$rc" -ne 0 ] && [ ! -f "$REAL_SENAL" ] && grep -q NEGADO "$LOG"; then
      echo "ok: $desc"
    else
      echo "FALLA: $desc (rc=$rc, log=$(head -c 120 "$LOG" 2>/dev/null))"; fallas=$((fallas+1))
    fi
  fi
}
correr "main:main negado"       no system event --mode now --session-key agent:main:main --text x
correr "vigia-mac negado"       no system event --mode now --session-key agent:main:vigia-mac --text x
correr "sesion propia real"     si system event --mode now --timeout 10000 --session-key agent:main:sim9-arnes19-zcode --text x
correr "clave forastera negada" no system event --mode now --session-key agent:otro:algo --text x
correr "comando forastero negado" no status --json
rm -f "$REAL_SENAL"; : > "$LOG"
out=$(DOBLE_LOG="$LOG" OPENCLAW_REAL_BIN="$REAL" bash "$PASARELA" message send --channel telegram -t destino --json -m hola 2>/dev/null)
if printf '%s' "$out" | grep -q '"messageId"' && [ ! -f "$REAL_SENAL" ] && grep -q '"mono_ns"' "$LOG"; then
  echo "ok: message send doblado"
else
  echo "FALLA: message send doblado (out=$out)"; fallas=$((fallas+1))
fi
out=$(DOBLE_LOG="$LOG" OPENCLAW_REAL_BIN="$REAL" bash "$PASARELA" cron list --json 2>/dev/null)
if printf '%s' "$out" | grep -q arnes-canal && [ ! -f "$REAL_SENAL" ]; then
  echo "ok: cron list doblado"
else
  echo "FALLA: cron list doblado"; fallas=$((fallas+1))
fi
# F2 (19.5): el argv registrado en doble.jsonl empieza en el subcomando de
# openclaw; el estado viaja en su propio campo, no al frente del argv.
python3 - "$LOG" <<'PY' || { echo "FALLA: el argv del log no empieza en system|cron|message"; fallas=$((fallas+1)); }
import json, sys
filas = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
malas = [r for r in filas if not r.get("argv") or r["argv"][0] not in ("system", "cron", "message")]
assert not malas, malas
PY

[ "$fallas" -eq 0 ] && echo "PASARELA: 6/6 ok" || { echo "PASARELA: $fallas fallas"; exit 1; }
