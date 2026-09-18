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

corrida_id_valido() { # $1 id; 0 = solo [A-Za-z0-9_-] (nada de /, .., :, ;)
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
  return 0
}

json_campo() { # $1 archivo, $2 campo punto (p.ej. simulacro, canal.destino)
  JARCH="$1" JCAMPO="$2" python3 -c "
import json,os
d=json.load(open(os.environ['JARCH']))
v=d
for k in os.environ['JCAMPO'].split('.'):
  v=v.get(k) if isinstance(v,dict) else None
print('' if v is None else (str(v).lower() if isinstance(v,bool) else v))
" 2>/dev/null
}

# Actualizacion del registro con lock por directorio y renombre atomico: dos
# lanzar-sesion en paralelo no se pisan y un corte a mitad no deja JSON truncado.
registro_actualizar() { # $1 registro, $2 lineas python que mutan d (env visible); 0 = escrito
  local reg="$1" dir i=0
  dir="$(dirname "$reg")"
  while ! mkdir "$dir/.lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 100 ] && { echo "registro_actualizar: lock del registro no cede" >&2; return 1; }
    sleep 0.1
  done
  CORR_REG="$reg" CORR_PY="$2" python3 -c "
import json,os
r=os.environ['CORR_REG']
d=json.load(open(r))
exec(os.environ['CORR_PY'])
t=r+'.tmp'
open(t,'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(t,0o600)
os.rename(t,r)
"
  local rc=$?
  rmdir "$dir/.lock" 2>/dev/null
  return "$rc"
}

jerga_en_texto() { # $1 archivo; 0 = trae jerga
  local m="$1" c
  grep -q '`' "$m" && return 0
  grep -qE '/[A-Za-z0-9_.-]' "$m" && return 0
  grep -qE '(^|[[:space:]])--[A-Za-z]' "$m" && return 0
  # sha: 7-40 hex Y al menos un digito y una letra; "acabada" o "1234567" solos pasan.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in
      *[0-9]*) printf '%s' "$c" | grep -q '[a-f]' && return 0;;
    esac
  done <<EOF
$(grep -oE '\b[0-9a-f]{7,40}\b' "$m")
EOF
  # lista negra: stems con plurales y participios (commits, merged, mergeado, PRs...).
  grep -qiE '\b(commits?|commitead[oa]s?|merges?|merged|mergead[oa]s?|mergearon|prs?|worktrees?|branches?|ci|hooks?|scripts?)\b' "$m" && return 0
  return 1
}

# Validador de seguimiento.v1 (misma regla que test-cli-modos.sh 9.1; 9.2 la reusa aqui).
# Cuatro lineas: etiqueta cerrada y los prefijos "Que cambio: ", "Que sigue: ",
# "Que necesito de ti: " en las lineas 2-4. El prefijo "[SIMULACRO] " solo va en la
# primera linea y se valida sobre una copia. El marcador "Comando: " es la referencia
# textual que el contrato permite: UN segmento al final de la linea 4, solo en
# "NECESITO TU RESPUESTA"; fuera de esa etiqueta o repetido es rojo.
mensaje_valido() { # $1 archivo; 0 = cumple seguimiento.v1
  local m="$1" primera etq nmarc seg
  [ -f "$m" ] || return 1
  [ "$(wc -l < "$m")" -eq 4 ] || return 1
  local C; C="$(mktemp)" || return 1
  cp "$m" "$C"
  primera="$(head -1 "$C")"
  if printf '%s\n' "$primera" | grep -q '^\[SIMULACRO\] '; then
    sed -i.bak '1s/^\[SIMULACRO\] //' "$C" && rm -f "$C.bak"
  fi
  head -1 "$C" | grep -qE '^\[(AVANZA|DETENIDA|NECESITO TU RESPUESTA|CERRADA)\] ' || { rm -f "$C"; return 1; }
  awk 'NR==2 && !/^Que cambio: /{m=1} NR==3 && !/^Que sigue: /{m=1} NR==4 && !/^Que necesito de ti: /{m=1} END{exit m?1:0}' "$C" \
    || { rm -f "$C"; return 1; }
  etq="$(head -1 "$C")"; etq="${etq%%]*}"; etq="${etq#[}"
  nmarc="$(awk 'NR==4{print gsub(/Comando: /,"")}' "$C")"
  if [ "$etq" = "NECESITO TU RESPUESTA" ]; then
    [ "$nmarc" -le 1 ] || { rm -f "$C"; return 1; }
    if [ "$nmarc" -eq 1 ]; then
      seg="$(sed -n '4s/^.*Comando: //p' "$C")"
      [ -n "$seg" ] || { rm -f "$C"; return 1; }
      sed -i.bak '4s/Comando: .*$//' "$C" && rm -f "$C.bak"
    fi
  else
    [ "$nmarc" -eq 0 ] || { rm -f "$C"; return 1; }
  fi
  if jerga_en_texto "$C"; then rm -f "$C"; return 1; fi
  rm -f "$C"
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
  local texto rc=0 sil=""
  # seguimiento.v1: lo rutinario (AVANZA, CERRADA) en silencio; DETENIDA y
  # NECESITO TU RESPUESTA suenan: en la etiqueta que pide respuesta, fallar hacia
  # silencio es el peor sentido de fallar.
  case "$etq" in AVANZA|CERRADA) sil="--silent";; esac
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
