#!/bin/bash
# corrida/lib.sh — biblioteca de corrida.sh (Fase 9, 9.2). No se ejecuta sola.
# Todo subcomando lee del registro; nada del entorno salvo los _BIN y CORRIDA_STATE.
# Compatible con /bin/bash 3.2 de macOS.
CORRIDA_STATE="${CORRIDA_STATE:-$HOME/.local/state/corridas}"
OPENCLAW_BIN="${OPENCLAW_BIN:-$HOME/.openclaw/bin/openclaw}"
if [ -z "${TMUX_BIN:-}" ]; then
  TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
  [ -z "$TMUX_BIN" ] && [ -x /opt/homebrew/bin/tmux ] && TMUX_BIN=/opt/homebrew/bin/tmux
fi

registro_de() { printf '%s/%s/registro.json' "$CORRIDA_STATE" "$1"; }

json_campo() { # $1 archivo, $2 campo punto (p.ej. simulacro, canal.destino)
  python3 -c "
import json,sys
d=json.load(open('$1'))
v=d
for k in '$2'.split('.'):
  v=v.get(k) if isinstance(v,dict) else None
print('' if v is None else (str(v).lower() if isinstance(v,bool) else v))
" 2>/dev/null
}

# Validador de seguimiento.v1 (misma regla que test-cli-modos.sh 9.1; 9.2 la reusa aqui).
# Acepta un prefijo "[SIMULACRO] " en la primera linea: se valida el mensaje base.
jerga_en_texto() { # $1 archivo; 0 = trae jerga
  grep -q '`' "$1" && return 0
  grep -qE '/[A-Za-z0-9_.-]' "$1" && return 0
  grep -qE '(^|[[:space:]])--[A-Za-z]' "$1" && return 0
  grep -qE '\b[0-9a-f]{7,40}\b' "$1" && return 0
  grep -qiE '\b(commit|merge|pr|worktree|branch|ci|hook|script)\b' "$1" && return 0
  return 1
}

mensaje_valido() { # $1 archivo; 0 = cumple seguimiento.v1
  local m="$1" primera
  [ -f "$m" ] || return 1
  primera="$(head -1 "$m")"
  case "$primera" in '[SIMULACRO]\ '*) tail -n +1 "$m" | sed 's/^\[SIMULACRO\] //' > "$m.tmp" && mv "$m.tmp" "$m";; esac
  [ "$(wc -l < "$m")" -eq 4 ] || return 1
  head -1 "$m" | grep -qE '^\[(AVANZA|DETENIDA|NECESITO TU RESPUESTA|CERRADA)\] ' || return 1
  jerga_en_texto "$m" && return 1
  return 0
}

tsv_fila() { # $1 tsv, $2 cli -> "binario|flag|barra" (vacio si no hay fila)
  awk -F'\t' -v c="$2" '$1==c && $1 !~ /^#/ {print $2"|"$3"|"$4; exit}' "$1"
}

# corrida_mensaje <id> <ETIQUETA> <cambio> <sigue> <necesito>
# Valida contra seguimiento.v1 ANTES de mandar; anota en mensajes.jsonl; 0 = enviado.
corrida_mensaje() {
  local id="$1" etq="$2" cambio="$3" sigue="$4" necesito="$5"
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local sim; sim="$(json_campo "$reg" simulacro)"
  local M; M="$(mktemp)" || return 1
  {
    printf '[%s] Fase 9\n' "$etq"
    printf 'Que cambio: %s\n' "$cambio"
    printf 'Que sigue: %s\n' "$sigue"
    printf 'Que necesito de ti: %s\n' "$necesito"
  } > "$M"
  mensaje_valido "$M" || { echo "mensaje fuera de contrato" >&2; rm -f "$M"; return 1; }
  [ "$sim" = "true" ] && sed -i.bak '1s/^/[SIMULACRO] /' "$M" && rm -f "$M.bak"
  local dest; dest="$(json_campo "$reg" canal.destino)"
  [ -n "$dest" ] || { echo "registro sin destino" >&2; rm -f "$M"; return 1; }
  local texto rc=0 sil="--silent"
  # seguimiento.v1: rutina en silencio; NECESITO TU RESPUESTA con notificacion.
  [ "$etq" = "NECESITO TU RESPUESTA" ] && sil=""
  texto="$(cat "$M")"
  "$OPENCLAW_BIN" message send --channel telegram -t "$dest" $sil --json -m "$texto" >/dev/null 2>&1 || rc=1
  CORR_MSG_ETQ="$etq" CORR_MSG_OK="$rc" CORR_MSG_DIR="$CORRIDA_STATE/$id" python3 -c "
import json,os
d={'etiqueta':os.environ['CORR_MSG_ETQ'],'ok':os.environ['CORR_MSG_OK']=='0'}
open(os.path.join(os.environ['CORR_MSG_DIR'],'mensajes.jsonl'),'a').write(json.dumps(d)+chr(10))
" 2>/dev/null
  rm -f "$M"
  return $rc
}
