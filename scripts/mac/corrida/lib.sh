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

# Locks con lease de dueno. El token empieza con el PID y se publica por rename.
# Un lock viejo solo se rompe si el token no cambio Y su PID ya no vive; la edad
# por si sola nunca autoriza robarlo. Un dispatcher EXIT unico conoce ambos locks,
# los limpia por token y despues ejecuta exactamente una vez cualquier trap EXIT
# que ya tuviera el llamador.
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

lock_token_publicar() { # $1 dir, $2 token
  local tmp="$1/token.tmp.$$"
  printf '%s' "$2" >"$tmp" || return 1
  mv -f "$tmp" "$1/token" || { rm -f "$tmp"; return 1; }
}

lock_reclamo_deshacer() { # $1 ruta original, $2 tumba reclamada
  if [ -e "$1" ]; then
    rm -rf "$2"
  else
    mv "$2" "$1" 2>/dev/null || rm -rf "$2"
  fi
}

lock_abandonado_romper() { # $1 dir, $2 umbral, $3 etiqueta; 0 = roto
  local d="$1" umbral="$2" etiqueta="$3" token="" pid actual tumba tenia_token=0
  [ -d "$d" ] && lock_viejo "$d" "$umbral" || return 1
  if [ -f "$d/token" ]; then
    tenia_token=1
    token="$(cat "$d/token" 2>/dev/null)" || return 1
    pid="${token%%-*}"
    case "$pid" in
      ''|*[!0-9]*) return 1;;
    esac
    kill -0 "$pid" 2>/dev/null && return 1
    actual="$(cat "$d/token" 2>/dev/null)" || return 1
    [ "$actual" = "$token" ] || return 1
  else
    # Compatibilidad con locks manuales/antiguos: confirmar que el token no
    # aparecio mientras se comprobaba la edad del directorio.
    [ ! -e "$d/token" ] || return 1
  fi
  # El rename reclama el directorio completo antes de borrar nada. Desde este
  # punto otro proceso puede crear un lock nuevo en $d sin que la limpieza de
  # esta tumba pueda tocarlo.
  tumba="$d.muerto.$$-${RANDOM:-0}"
  [ ! -e "$tumba" ] || return 1
  mv "$d" "$tumba" 2>/dev/null || return 1
  if [ "$tenia_token" -eq 1 ]; then
    actual="$(cat "$tumba/token" 2>/dev/null)" || {
      lock_reclamo_deshacer "$d" "$tumba"; return 1;
    }
    [ "$actual" = "$token" ] || {
      lock_reclamo_deshacer "$d" "$tumba"; return 1;
    }
  elif [ -e "$tumba/token" ]; then
    lock_reclamo_deshacer "$d" "$tumba"
    return 1
  fi
  rm -rf "$tumba" || return 1
  echo "$etiqueta: rompio un lock viejo sin proceso vivo" >&2
  return 0
}

lock_directorio_soltar() { # $1 dir, $2 token; solo el dueno lo elimina
  local d="$1" token="$2"
  [ -n "$d" ] || return 0
  [ -f "$d/token" ] || return 0
  [ "$(cat "$d/token" 2>/dev/null)" = "$token" ] || return 0
  rm -f "$d/token"
  rmdir "$d" 2>/dev/null
}

locks_exit_despachar() {
  local estado="$?" previo citado
  lock_directorio_soltar "${CORR_LOCK_ACT:-}" "${CORR_LOCK_TOKEN:-}"
  lock_directorio_soltar "${MARCAS_LOCK_ACT:-}" "${MARCAS_LOCK_TOKEN:-}"
  CORR_LOCK_ACT=""; CORR_LOCK_TOKEN=""
  MARCAS_LOCK_ACT=""; MARCAS_LOCK_TOKEN=""
  previo="${LOCKS_EXIT_PREV:-}"
  LOCKS_EXIT_PREV=""; LOCKS_EXIT_ARMADO=0
  trap - EXIT
  if [ -n "$previo" ]; then
    citado="${previo#trap -- }"
    citado="${citado% EXIT}"
    eval "set -- $citado"
    eval "$1"
  fi
  return "$estado"
}

locks_exit_armar() {
  [ "${LOCKS_EXIT_ARMADO:-0}" = "1" ] && return 0
  LOCKS_EXIT_PREV="$(trap -p EXIT)"
  LOCKS_EXIT_ARMADO=1
  trap 'locks_exit_despachar' EXIT
}

locks_exit_restaurar_si_libre() {
  local previo
  [ -z "${CORR_LOCK_ACT:-}" ] || return 0
  [ -z "${MARCAS_LOCK_ACT:-}" ] || return 0
  [ "${LOCKS_EXIT_ARMADO:-0}" = "1" ] || return 0
  previo="${LOCKS_EXIT_PREV:-}"
  trap - EXIT
  [ -n "$previo" ] && eval "$previo"
  LOCKS_EXIT_PREV=""; LOCKS_EXIT_ARMADO=0
}

lock_tomar() { # $1 registro; 0 = tomado y registrado en el dispatcher EXIT
  local dir i=0 token
  dir="$(dirname "$1")"
  lock_abandonado_romper "$dir/.lock" "$CORR_LOCK_VIEJO" "lock_tomar" || true
  while ! mkdir "$dir/.lock" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 100 ] && return 1
    sleep 0.1
  done
  token="$$-${RANDOM:-0}"
  lock_token_publicar "$dir/.lock" "$token" \
    || { rmdir "$dir/.lock" 2>/dev/null; return 1; }
  CORR_LOCK_TOKEN="$token"
  CORR_LOCK_ACT="$dir/.lock"
  locks_exit_armar
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

lock_soltar() { # $1 registro; solo suelta el token propio
  local d token
  d="$(dirname "$1")/.lock"; token="${CORR_LOCK_TOKEN:-}"
  CORR_LOCK_ACT=""; CORR_LOCK_TOKEN=""
  lock_directorio_soltar "$d" "$token"
  locks_exit_restaurar_si_libre
}

# Lock global e independiente para el nombre/las marcas de sesiones tmux. No usa
# CORR_LOCK_TOKEN ni CORR_LOCK_ACT: lanzar-sesion necesita mantenerlo mientras
# toma tambien el lock de su registro. Reconciliar usa el mismo lock desde el
# snapshot de list-sessions hasta el ultimo unset, cerrando el TOCTOU por nombre.
marcas_lock_tomar() {
  local d="$CORRIDA_STATE/.marcas.lock" i=0 token
  mkdir -p "$CORRIDA_STATE" || return 1
  lock_abandonado_romper "$d" "$CORR_LOCK_VIEJO" "marcas_lock_tomar" || true
  while ! mkdir "$d" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 100 ] && return 1
    sleep 0.1
  done
  token="$$-${RANDOM:-0}"
  lock_token_publicar "$d" "$token" || { rmdir "$d" 2>/dev/null; return 1; }
  MARCAS_LOCK_TOKEN="$token"
  MARCAS_LOCK_ACT="$d"
  locks_exit_armar
  return 0
}

marcas_lock_refrescar() {
  local t="${MARCAS_LOCK_ACT:-}/token"
  [ -f "$t" ] || return 0
  [ "$(cat "$t" 2>/dev/null)" = "${MARCAS_LOCK_TOKEN:-}" ] && touch "$t" 2>/dev/null
  return 0
}

marcas_lock_soltar() {
  local d="${MARCAS_LOCK_ACT:-}" token="${MARCAS_LOCK_TOKEN:-}"
  [ -n "$d" ] || return 0
  MARCAS_LOCK_ACT=""; MARCAS_LOCK_TOKEN=""
  lock_directorio_soltar "$d" "$token"
  locks_exit_restaurar_si_libre
}

# Retira marcas solo si la corrida indicada sigue siendo su dueña publicada.
# Debe llamarse con el lock global de marcas tomado.
marca_retirar_si_dueno() { # $1 corrida, $2 sesion; otro/ningun dueno = no-op
  local id="$1" sesion="$2" dueno marca
  dueno="$("$TMUX_BIN" show-environment -t "=$sesion" OPENCLAW_WATCH_RUN 2>/dev/null || true)"
  [ "$dueno" = "OPENCLAW_WATCH_RUN=$id" ] || return 0
  marca="$("$TMUX_BIN" show-environment -t "=$sesion" OPENCLAW_WATCH 2>/dev/null || true)"
  if [ "$marca" = "OPENCLAW_WATCH=1" ]; then
    "$TMUX_BIN" set-environment -t "=$sesion" -u OPENCLAW_WATCH || return 1
  fi
  "$TMUX_BIN" set-environment -t "=$sesion" -u OPENCLAW_WATCH_RUN || return 1
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

# validar_registro: el criterio unico de corrida.v1/v2 vive aqui (la prueba 9.1
# carga este archivo); la lista dura es la regla 3 de 00-project-spec.
# Dual-read: v1 trae cron_vigia_id (el id del cron hombre-muerto por corrida);
# v2 trae seguimiento_global:true y NADA de cron_vigia_id (el reloj es el unico
# avance-tareas global). Lo que no sea exactamente una de las dos es ROTO.
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
schema=d.get('schema')
if schema=='corrida.v1':
  if not isinstance(d.get('cron_vigia_id'),str) or not d.get('cron_vigia_id'):
    malo('sin cron_vigia_id')
elif schema=='corrida.v2':
  if d.get('seguimiento_global') is not True: malo('sin seguimiento_global')
  if 'cron_vigia_id' in d: malo('v2 con cron_vigia_id')
else:
  malo('schema distinto')
for c in ('id','runbook'):
  if not d.get(c): malo('sin '+c)
canal=d.get('canal')
if not isinstance(canal,dict):
  malo('sin canal.cron'); malo('sin canal.destino')
else:
  if not canal.get('cron'): malo('sin canal.cron')
  if not canal.get('destino'): malo('sin canal.destino')
for c in ('cli_modos','inicio'):
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
# Caso cerrado por etiqueta:
# - AVANZA: valida contra seguimiento.v1 y acumula {at,cambio,sigue,necesito}
#   en eventos-seguimiento.jsonl para el proximo corte global. NO llama a
#   message send ni anota entrega en mensajes.jsonl: los llamadores viejos que
#   mandaban por cambio ya no pueden saltarse el consolidador de 30 minutos.
# - NECESITO TU RESPUESTA, DETENIDA, CERRADA: entrega inmediata por
#   seguimiento.v1 con su fila en mensajes.jsonl, como siempre.
# - Cualquier otra etiqueta falla cerrada: no se acumula ni se manda nada.
corrida_mensaje() {
  local id="$1" etq="$2" avance="$3" cambio="$4" sigue="$5" necesito="$6"
  local reg; reg="$(registro_de "$id")"
  [ -f "$reg" ] || { echo "sin registro: $id" >&2; return 1; }
  case "$etq" in
    AVANZA|NECESITO\ TU\ RESPUESTA|DETENIDA|CERRADA) ;;
    *) echo "corrida_mensaje: etiqueta fuera del conjunto: $etq" >&2; return 1;;
  esac
  local sim; sim="$(json_campo "$reg" simulacro)"
  local M; M="$(mktemp)" || return 1
  {
    printf '[%s] Corrida, %s\n' "$etq" "$avance"
    printf 'Que cambio: %s\n' "$cambio"
    printf 'Que sigue: %s\n' "$sigue"
    printf 'Que necesito de ti: %s\n' "$necesito"
  } > "$M"
  mensaje_valido "$M" || { echo "mensaje fuera de contrato" >&2; rm -f "$M"; return 1; }
  rm -f "$M"
  if [ "$etq" = "AVANZA" ]; then
    local evdir evtmp now
    evdir="$(dirname "$reg")"
    now="$(date +%Y-%m-%dT%H:%M:%S%z)"
    evtmp="$(mktemp)" || return 1
    CORR_MSG_CAMBIO="$cambio" CORR_MSG_SIGUE="$sigue" CORR_MSG_NECESITO="$necesito" CORR_MSG_AT="$now" \
    python3 -c "
import json,os
d={'at':os.environ['CORR_MSG_AT'],'cambio':os.environ['CORR_MSG_CAMBIO'],
'sigue':os.environ['CORR_MSG_SIGUE'],'necesito':os.environ['CORR_MSG_NECESITO']}
open('$evtmp','w').write(json.dumps(d)+chr(10))
" 2>/dev/null || { rm -f "$evtmp"; echo "corrida_mensaje: no se pudo acumular el evento" >&2; return 1; }
    if [ ! -e "$evdir/eventos-seguimiento.jsonl" ]; then
      : > "$evdir/eventos-seguimiento.jsonl" && chmod 600 "$evdir/eventos-seguimiento.jsonl"
    fi
    cat "$evtmp" >> "$evdir/eventos-seguimiento.jsonl" || { rm -f "$evtmp"; echo "corrida_mensaje: no se pudo acumular el evento" >&2; return 1; }
    rm -f "$evtmp"
    return 0
  fi
  local M2; M2="$(mktemp)" || return 1
  {
    printf '[%s] Corrida, %s\n' "$etq" "$avance"
    printf 'Que cambio: %s\n' "$cambio"
    printf 'Que sigue: %s\n' "$sigue"
    printf 'Que necesito de ti: %s\n' "$necesito"
  } > "$M2"
  [ "$sim" = "true" ] && sed -i.bak '1s/^/[SIMULACRO] /' "$M2" && rm -f "$M2.bak"
  local dest; dest="$(json_campo "$reg" canal.destino)"
  [ -n "$dest" ] || { echo "registro sin destino" >&2; rm -f "$M2"; return 1; }
  local texto rc=0 sil=""
  # seguimiento.v1: lo rutinario (CERRADA) en silencio; DETENIDA y
  # NECESITO TU RESPUESTA suenan: en la etiqueta que pide respuesta, fallar hacia
  # silencio es el peor sentido de fallar.
  case "$etq" in CERRADA) sil="--silent";; esac
  texto="$(cat "$M2")"
  con_tope "$CORR_TOPE_RED" "$OPENCLAW_BIN" message send --channel telegram -t "$dest" $sil --json -m "$texto" >/dev/null 2>&1 || rc=1
  CORR_MSG_ETQ="$etq" CORR_MSG_OK="$rc" CORR_MSG_DIR="$CORRIDA_STATE/$id" python3 -c "
import json,os
d={'etiqueta':os.environ['CORR_MSG_ETQ'],'ok':os.environ['CORR_MSG_OK']=='0'}
open(os.path.join(os.environ['CORR_MSG_DIR'],'mensajes.jsonl'),'a').write(json.dumps(d)+chr(10))
" 2>/dev/null
  rm -f "$M2"
  return $rc
}
