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

runbook_de() { # $1 runbook del registro: la absoluta, tal cual; la relativa, bajo REPO_DIR
  case "$1" in
    /*) printf '%s\n' "$1";;
    *) printf '%s/%s\n' "${REPO_DIR:-$(pwd)}" "$1";;
  esac
}

# Actualizacion del registro con lock por directorio y renombre atomico: dos
# lanzar-sesion en paralelo no se pisan y un corte a mitad no deja JSON truncado.
# Un lock de mas de 60 s es de un proceso muerto: se rompe con aviso y se sigue.
registro_actualizar() { # $1 registro, $2 lineas python que mutan d (env visible); 0 = escrito
  local reg="$1" dir i=0
  dir="$(dirname "$reg")"
  if [ -d "$dir/.lock" ] && [ -n "$(find "$dir/.lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$dir/.lock" 2>/dev/null \
      && echo "registro_actualizar: rompio un lock de mas de 60 s en $dir" >&2
  fi
  while ! mkdir "$dir/.lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 100 ] && { echo "registro_actualizar: lock del registro no cede" >&2; return 1; }
    sleep 0.1
  done
  # Si quien escribe muere dentro de la seccion critica, un EXIT sin dueno saca el
  # lock. Si el llamador ya tiene su propio trap (p. ej. el de preflight), no se le
  # pisa: ese caso lo cubre el rompimiento de locks viejos. Nada de guardar y
  # restaurar traps: restaurar dentro de una subshell de captura dispara el trap
  # ajeno al cerrar ella (medido: borro el dir de una prueba a mitad de corrida).
  if [ -z "$(trap -p EXIT)" ]; then
    CORR_LOCK_ACT="$dir/.lock"
    trap 'rmdir "$CORR_LOCK_ACT" 2>/dev/null' EXIT
  fi
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

# validar_registro: el criterio unico de corrida.v1 vive aqui (la prueba 9.1 carga
# este archivo); la lista dura es la regla 3 de 00-project-spec.
validar_registro() { # $1 json del registro; 0 = valido; imprime ROTO:<motivo> por defecto
  VREG="$1" python3 <<'PY' 2>/dev/null
import json,os,re,sys
try:
  d=json.load(open(os.environ['VREG']))
  assert isinstance(d,dict)
except Exception:
  print('ROTO:no es json'); sys.exit(1)
e=[]
def malo(m):
  if m not in e: e.append(m)
if d.get('vigia') not in ('claw','hermes'): malo('vigia fuera del conjunto')
if d.get('schema')!='corrida.v1': malo('schema distinto')
for c in ('id','runbook'):
  if not d.get(c): malo('sin '+c)
if not (isinstance(d.get('canal'),dict) and d['canal'].get('cron')): malo('sin canal.cron')
if d.get('estado') not in ('abierta','cerrada'): malo('estado fuera del conjunto')
tb=d.get('timebox_horas')
if isinstance(tb,bool) or not isinstance(tb,int): malo('timebox no numerico')
elif tb<1: malo('timebox fuera de rango')
ss=d.get('sesiones')
# Cero sesiones es valido en una corrida recien abierta (abrir escribe la lista vacia);
# lo que no admite es que sesiones no sea lista o que cada elemento falle su forma.
if not isinstance(ss,list): malo('sesiones no es lista')
else:
  for s in ss:
    for c in ('nombre','rol','cli','dueno','dir'):
      if not (isinstance(s,dict) and s.get(c)): malo('sesion sin '+c); break
    if isinstance(s,dict) and s.get('rol') not in (None,'lead','carril'):
      malo('rol fuera del conjunto')
# Lista dura por regexes con bordes de palabra: "rm -rf" y "force push" caen,
# "emergencia" y "dropbox" (que contienen "merge"/"drop" como substring) no.
DURA=[r'\brm\s+-[a-z]*r[a-z]*f', r'\bdrop\b', r'\bborr\w*\s+recursiv\w*',
      r'\bforce\s+push\b', r'\bpush\b[^\n]{0,40}\b(main|por defecto)\b',
      r'\bmerge\w*\b', r'\bcredenciales?\b', r'\btokens?\b', r'\bsecretos?\b']
for p in d.get('preaprobaciones') or []:
  if not isinstance(p,dict): malo('preaprobacion sin forma'); continue
  if p.get('decision') not in ('Aprobado','Negado'): malo('decision fuera del conjunto')
  pat=str(p.get('patron','')).lower()
  if p.get('decision')=='Aprobado' and any(re.search(k,pat) for k in DURA):
    malo('lista dura aprobada: '+pat)
for m in e: print('ROTO:'+m)
sys.exit(1 if e else 0)
PY
}

jerga_en_texto() { # $1 archivo; 0 = trae jerga
  local m="$1" c
  grep -q '`' "$m" && return 0
  grep -qE '/[A-Za-z0-9_.-]' "$m" && return 0
  grep -qE '(^|[[:space:]])--[A-Za-z]' "$m" && return 0
  grep -qE '#[0-9]+' "$m" && return 0
  # sha: 7-40 hex Y al menos un digito y una letra; "acabada" o "1234567" solos pasan.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in
      *[0-9]*) printf '%s' "$c" | grep -q '[a-f]' && return 0;;
    esac
  done <<EOF
$(grep -oE '\b[0-9a-f]{7,40}\b' "$m")
EOF
  # sha en mayusculas: misma regla con [A-F].
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in
      *[0-9]*) printf '%s' "$c" | grep -q '[A-F]' && return 0;;
    esac
  done <<EOF
$(grep -oE '\b[0-9A-F]{7,40}\b' "$m")
EOF
  # lista negra: stems con plurales y participios (commits, merged, mergeado, PRs,
  # mergear, rebase, push, pull request, repo, rama...).
  grep -qiE '\b(commits?|commitead[oa]s?|commitea\w*|merges?|merged|mergead[oa]s?|mergearon|mergear\w*|mergeo\w*|rebase\w*|push\w*|pull request|prs?|worktrees?|branches?|ramas?|repos?|ci|hooks?|scripts?)\b' "$m" && return 0
  return 1
}

# Validador de seguimiento.v1 — el criterio unico vive aqui y la prueba 9.1 lo
# ejercita. Cuatro lineas: etiqueta cerrada y avance "N de M partes" en la linea 1
# (CERRADA queda solo con resto no vacio: ya no hay nada que contar), prefijos
# "Que cambio: ", "Que sigue: ", "Que necesito de ti: " con contenido no vacio.
# El prefijo "[SIMULACRO] " se quita de la primera linea y se valida sobre una copia.
# El marcador "Comando: " es la referencia textual del contrato: UN segmento al
# final de la linea 4, solo en "NECESITO TU RESPUESTA", con contenido no vacio y
# de hasta 200 caracteres; en las lineas 1-3, fuera de esa etiqueta o repetido es rojo.
mensaje_valido() { # $1 archivo; 0 = cumple seguimiento.v1
  local m="$1" primera etq resto nmarc seg
  [ -f "$m" ] || return 1
  [ "$(awk 'END{print NR}' "$m")" -eq 4 ] || return 1
  local C; C="$(mktemp)" || return 1
  cp "$m" "$C"
  sed -i.bak '1s/^\[SIMULACRO\] //' "$C" && rm -f "$C.bak"
  primera="$(head -1 "$C")"
  printf '%s\n' "$primera" | grep -qE '^\[(AVANZA|DETENIDA|NECESITO TU RESPUESTA|CERRADA)\] ' || { rm -f "$C"; return 1; }
  etq="${primera%%]*}"; etq="${etq#[}"
  resto="${primera#*] }"
  [ -n "$resto" ] || { rm -f "$C"; return 1; }
  if [ "$etq" != "CERRADA" ]; then
    printf '%s\n' "$resto" | grep -qE '[0-9]+ de [0-9]+ partes' || { rm -f "$C"; return 1; }
  fi
  awk 'NR==2 && !/^Que cambio: .+/ {m=1} NR==3 && !/^Que sigue: .+/ {m=1} NR==4 && !/^Que necesito de ti: .+/ {m=1} END{exit m?1:0}' "$C" \
    || { rm -f "$C"; return 1; }
  awk 'NR<=3 && /Comando: /{m=1} END{exit m?1:0}' "$C" || { rm -f "$C"; return 1; }
  nmarc="$(awk 'NR==4{print gsub(/Comando: /,"")}' "$C")"
  if [ "$etq" = "NECESITO TU RESPUESTA" ]; then
    [ "$nmarc" -le 1 ] || { rm -f "$C"; return 1; }
    if [ "$nmarc" -eq 1 ]; then
      seg="$(sed -n '4s/^.*Comando: //p' "$C")"
      [ -n "$seg" ] && [ "${#seg}" -le 200 ] || { rm -f "$C"; return 1; }
      sed -i.bak '4s/Comando: .*$//' "$C" && rm -f "$C.bak"
    fi
  else
    [ "$nmarc" -eq 0 ] || { rm -f "$C"; return 1; }
  fi
  # La linea 4 siempre trae la pregunta: no vale solo el comando textual.
  awk 'NR==4{sub(/^Que necesito de ti: /,""); sub(/[[:space:]]+$/,""); exit ($0=="")?1:0}' "$C" \
    || { rm -f "$C"; return 1; }
  if jerga_en_texto "$C"; then rm -f "$C"; return 1; fi
  rm -f "$C"
  return 0
}

tsv_fila() { # $1 tsv, $2 cli -> "binario|flag|barra" (vacio si no hay fila)
  awk -F'\t' -v c="$2" '$1==c && $1 !~ /^#/ {print $2"|"$3"|"$4; exit}' "$1"
}

# corrida_mensaje <id> <ETIQUETA> <avance> <cambio> <sigue> <necesito>
# El avance es la linea 1 tras "Fase 9, " (p. ej. "2 de 5 partes terminadas").
# Valida contra seguimiento.v1 ANTES de mandar; anota en mensajes.jsonl; 0 = enviado.
corrida_mensaje() {
  local id="$1" etq="$2" avance="$3" cambio="$4" sigue="$5" necesito="$6"
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local sim; sim="$(json_campo "$reg" simulacro)"
  local M; M="$(mktemp)" || return 1
  {
    printf '[%s] Fase 9, %s\n' "$etq" "$avance"
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
