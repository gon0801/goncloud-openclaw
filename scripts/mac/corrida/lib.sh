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
# Raiz del repo derivada del propio lib.sh al cargarse (corrida/ esta a tres niveles:
# scripts/mac/corrida). Instalado vive en ~/bin/corrida/ y la derivacion no aplica
# (documentado): ahi mandan REPO_DIR o los runbooks absolutos del registro.
CORR_REPO_RAIZ="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd || true)"

registro_de() { printf '%s/%s/registro.json' "$CORRIDA_STATE" "$1"; }

corrida_id_valido() { # $1 id; 0 = solo [A-Za-z0-9_-] (nada de /, .., :, ;)
  case "$1" in ''|*[!A-Za-z0-9_-]*) return 1;; esac
  return 0
}

# Tope de reloj para las llamadas de red: cerrar retiene el lock mientras habla
# con el gateway, y una llamada colgada no puede superar el umbral de locks viejos
# (un proceso vivo con el lock roto es peor que un error oportuno).
con_tope() { # $1 segundos; resto: comando a correr con tope (SIGALRM al vencer)
  local seg="$1"; shift
  perl -e 'alarm shift; exec(@ARGV) or exit 127' "$seg" "$@"
}
CORR_TOPE_RED="${CORR_TOPE_RED:-30}"

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

runbook_de() { # $1 runbook del registro: la absoluta, tal cual; la relativa, contra
               # REPO_DIR si esta inyectado; si no, la raiz derivada del propio
               # lib.sh. pwd queda solo como ultimo recurso documentado si la
               # derivacion fallara — nada de esto lo garantiza todavia el plist
               # (carril M): bajo launchd, inyectar REPO_DIR es lo seguro.
  local base="${REPO_DIR:-}"
  [ -n "$base" ] || base="$CORR_REPO_RAIZ"
  [ -n "$base" ] || base="$(pwd)"
  case "$1" in
    /*) printf '%s\n' "$1";;
    *) printf '%s/%s\n' "$base" "$1";;
  esac
}

# Parser unico de `cron list --json`: por nombre, el destino de entrega o TODOS los
# ids (los duplicados homonimos existen: medido en vivo 2026-09-18). Sentinelas en
# stdout: ILEGIBLE (lista sin leer) y NINGUNO (legible, sin ese nombre).
cron_dest_de() { # $1 nombre -> destino de entrega. Con crons homonimos: si todos
                 # traen createdAtMs, gana el mas reciente; si no, mismo destino en
                 # todos -> ese; destinos DISTINTOS -> AMBIGUO (que abrir falle).
  printf '%s' "$(con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron list --json 2>/dev/null)" | NOMBRE_CRON="$1" python3 -c "
import sys,json,os
t=sys.stdin.read()
try:
  d=json.loads(t[t.index('{'):])
except Exception:
  print('ILEGIBLE'); raise SystemExit
js=[j for j in d.get('jobs',[]) if j.get('name')==os.environ['NOMBRE_CRON']]
if not js: print(''); raise SystemExit
dests=[(j.get('delivery') or {}).get('to') or '' for j in js]
def ms(j):
  v=j.get('createdAtMs')
  return v if isinstance(v,(int,float)) and not isinstance(v,bool) else None
if all(ms(j) is not None for j in js):
  i=max(range(len(js)), key=lambda k: ms(js[k]))
  print(dests[i]); raise SystemExit
print(dests[0] if len(set(dests))==1 else 'AMBIGUO')" 2>/dev/null
}

cron_jobs_de() { # $1 nombre -> ILEGIBLE | NINGUNO | un id por linea
  printf '%s' "$(con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" cron list --json 2>/dev/null)" | NOMBRE_CRON="$1" python3 -c "
import sys,json,os
t=sys.stdin.read()
try:
  d=json.loads(t[t.index('{'):])
except Exception:
  print('ILEGIBLE'); raise SystemExit
js=[j.get('id','') for j in d.get('jobs',[]) if j.get('name')==os.environ['NOMBRE_CRON'] and j.get('id')]
print('\n'.join(js) if js else 'NINGUNO')" 2>/dev/null
}

# El lock del registro, en un solo lugar, con lease de dueno. Al tomar se escribe
# un token (.lock/token): la edad del lock es la del TOKEN, y su dueno vivo la
# refresca entre llamadas largas (lock_refrescar) — un lock refrescado jamas se
# roba, pase lo que pase debajo. Un lock sin token (manual, o de una version
# vieja) se envejece por el directorio. Pasado CORR_LOCK_VIEJO segundos sin
# refresco, el lock es de un proceso muerto y se rompe con aviso. Al tomar, se
# arma un trap de EXIT sin dueno (si el llamador ya tiene el suyo, como preflight,
# no se le pisa: ese caso lo cubre el rompimiento de locks viejos). Nada de
# guardar y restaurar traps: restaurar dentro de una subshell de captura dispara
# el trap ajeno al cerrar ella (medido: borro el dir de una prueba a mitad de
# corrida). Al soltar, el disarm va ANTES del rmdir: el EXIT de este proceso no
# puede romperle a otro un lock vivo tomado entremedias; y el lock solo lo
# elimina su dueno (el token calza) — un soltar ajeno no toca nada.
CORR_LOCK_VIEJO="${CORR_LOCK_VIEJO:-60}"
lock_viejo() { # $1 dir del lock, $2 umbral en segundos; 0 = viejo (rompible)
  local ref="$1/token"
  [ -f "$ref" ] || ref="$1"
  VIEJO_REF="$ref" VIEJO_UMBRAL="$2" python3 -c "
import os,sys,time
try: m=os.path.getmtime(os.environ['VIEJO_REF'])
except Exception: sys.exit(1)
sys.exit(0 if time.time()-m > float(os.environ['VIEJO_UMBRAL']) else 1)" 2>/dev/null
}
lock_tomar() { # $1 registro; 0 = tomado (token escrito; trap de EXIT si no habia dueno)
  local dir i=0
  dir="$(dirname "$1")"
  if [ -d "$dir/.lock" ] && lock_viejo "$dir/.lock" "$CORR_LOCK_VIEJO"; then
    rm -f "$dir/.lock/token"
    rmdir "$dir/.lock" 2>/dev/null \
      && echo "lock_tomar: rompio un lock viejo en $dir" >&2
  fi
  while ! mkdir "$dir/.lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 100 ] && return 1
    sleep 0.1
  done
  CORR_LOCK_TOKEN="$$-${RANDOM:-0}"
  printf '%s' "$CORR_LOCK_TOKEN" > "$dir/.lock/token"
  if [ -z "$(trap -p EXIT)" ]; then
    CORR_LOCK_ACT="$dir/.lock"
    CORR_LOCK_ARMADO=1
    trap 'rm -f "$CORR_LOCK_ACT/token"; rmdir "$CORR_LOCK_ACT" 2>/dev/null' EXIT
  fi
  return 0
}

lock_refrescar() { # $1 registro: re-touch del token, solo si este proceso sigue
                   # siendo el dueno (nada de touch ciego: no se revive lock ajeno)
  local t
  t="$(dirname "$1")/.lock/token"
  [ -f "$t" ] || return 0
  [ "$(cat "$t" 2>/dev/null)" = "${CORR_LOCK_TOKEN:-}" ] && touch "$t" 2>/dev/null
  return 0
}

lock_soltar() { # $1 registro: disarm ANTES del rmdir, solo si este proceso armo el trap
  local d t
  d="$(dirname "$1")/.lock"; t="$d/token"
  if [ "${CORR_LOCK_ARMADO:-0}" = "1" ]; then
    trap - EXIT
    CORR_LOCK_ARMADO=0
  fi
  if [ -f "$t" ] && [ "$(cat "$t" 2>/dev/null)" != "${CORR_LOCK_TOKEN:-}" ]; then
    return 0 # lock ajeno o robado: no es de quien suelta
  fi
  rm -f "$t"
  rmdir "$d" 2>/dev/null
}

registro_escribir() { # $1 registro, $2 lineas python que mutan d; 0 = escrito.
                     # SIN lock: quien llama lo toma con lock_tomar.
  CORR_REG="$1" CORR_PY="$2" python3 -c "
import json,os
r=os.environ['CORR_REG']
d=json.load(open(r))
exec(os.environ['CORR_PY'])
t=r+'.tmp'
open(t,'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(t,0o600)
os.rename(t,r)
"
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
canal=d.get('canal')
if not isinstance(canal,dict):
  malo('sin canal.cron'); malo('sin canal.destino')
else:
  if not canal.get('cron'): malo('sin canal.cron')
  if not canal.get('destino'): malo('sin canal.destino')
for c in ('cli_modos','cron_vigia_id','inicio'):
  if not d.get(c): malo('sin '+c)
if not isinstance(d.get('simulacro'),bool): malo('simulacro no es booleano')
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
# Lista dura por regexes con bordes de palabra: "force push" cae y "emergencia" o
# "dropbox" (que contienen "merge"/"drop" como substring) no. El rm recursivo va
# aparte y mira el resto COMPLETO del patron desde el "rm": los flags se extraen
# con findall y lookbehind (sobreviven comillas invertidas, comillas, comas y
# parentesis); una opcion larga cuenta si es "--recursive" o un PREFIJO suyo (el
# getopt de GNU abrevia: --r, --rec...; "--dir"/"--resto" no son prefijo y no
# cuentan); los cortos solo si TODAS sus letras son opciones de rm (d f i p r v w
# x) — la regla exige recursividad: una -f sola jamas cuenta.
def _rm_recursivo(pat):
  m=re.search(r'\brm\b', pat)
  if not m: return False
  for t in re.findall(r'(?<![\w-])-{1,2}[a-z]+', pat[m.end():]):
    if t.startswith('--'):
      c=t[2:]
      if c and 'recursive'.startswith(c): return True
      continue
    if set(t[1:]) <= set('dfiprvwx') and 'r' in t: return True
  return False
DURA=[r'\bdrop\b', r'\bborr\w*\s+recursiv\w*',
      r'\bforce\s+push\b', r'\bpush\b[^\n]{0,40}\b(main|por defecto)\b',
      r'\bmerge\w*\b', r'\bcredenciales?\b', r'\btokens?\b', r'\bsecretos?\b']
pa=d.get('preaprobaciones')
if pa is None: pa=[]
if not isinstance(pa,list):
  malo('preaprobaciones no es lista'); pa=[]
for p in pa:
  if not isinstance(p,dict): malo('preaprobacion sin forma'); continue
  if p.get('decision') not in ('Aprobado','Negado'): malo('decision fuera del conjunto')
  pat=str(p.get('patron','')).lower()
  if p.get('decision')=='Aprobado' and (_rm_recursivo(pat) or any(re.search(k,pat) for k in DURA)):
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
  # sha: 7-64 hex en cualquier caja Y al menos un digito y una letra; "acabada" o
  # "1234567" solos pasan, "Ab12Cd4" (mixto) o un sha256 de 64 no.
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in
      *[0-9]*) printf '%s' "$c" | grep -q '[a-fA-F]' && return 0;;
    esac
  done <<EOF
$(grep -oiE '\b[0-9a-f]{7,64}\b' "$m")
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
  local pref; pref="[$etq] "
  resto="${primera#"$pref"}"
  [ "$resto" = "$primera" ] && resto=""
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

# El binario de la tabla de modos jamas llega interpolado a un sh (un campo como
# "x; comando" es inyeccion, no un nombre): se valida contra [A-Za-z0-9_.-] y se
# resuelve como argumento posicional del command -v, nunca dentro del texto -c.
bin_de_tabla() { # $1 binario de la tabla; stdout su absoluta; rc 2 = invalido, 1 = no resuelve
  case "$1" in ''|*[!A-Za-z0-9_.-]*)
    echo "binario invalido en la tabla de modos: $1" >&2; return 2;; esac
  bash -c 'PATH="$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"; command -v "$1"' _ "$1" 2>/dev/null \
    || { echo "binario no arranca: $1" >&2; return 1; }
}

# El flag de la tabla viaja al mismo shell-command de tmux (sh -c): solo
# [A-Za-z0-9 _.=-] — el espacio queda ("--mode yolo", "-f --trust" existen medidos);
# un ";" o una comilla alli es inyeccion, no un flag.
flag_de_tabla() { # $1 flag de la tabla; rc 2 = invalido (mensaje a stderr)
  case "$1" in *[!A-Za-z0-9_.\ =-]*)
    echo "flag invalido en la tabla de modos: $1" >&2; return 2;; esac
  return 0
}

# corrida_mensaje <id> <ETIQUETA> <avance> <cambio> <sigue> <necesito>
# El avance es la linea 1 tras "Corrida, " (p. ej. "2 de 5 partes terminadas").
# Valida contra seguimiento.v1 ANTES de mandar; anota en mensajes.jsonl; 0 = enviado.
corrida_mensaje() {
  local id="$1" etq="$2" avance="$3" cambio="$4" sigue="$5" necesito="$6"
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  local sim; sim="$(json_campo "$reg" simulacro)"
  local M; M="$(mktemp)" || return 1
  {
    printf '[%s] Corrida, %s\n' "$etq" "$avance"
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
  con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" message send --channel telegram -t "$dest" $sil --json -m "$texto" >/dev/null 2>&1 || rc=1
  CORR_MSG_ETQ="$etq" CORR_MSG_OK="$rc" CORR_MSG_DIR="$CORRIDA_STATE/$id" python3 -c "
import json,os
d={'etiqueta':os.environ['CORR_MSG_ETQ'],'ok':os.environ['CORR_MSG_OK']=='0'}
open(os.path.join(os.environ['CORR_MSG_DIR'],'mensajes.jsonl'),'a').write(json.dumps(d)+chr(10))
" 2>/dev/null
  rm -f "$M"
  return $rc
}
