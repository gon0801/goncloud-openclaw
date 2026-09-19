#!/bin/bash
# corrida/responder.sh (9.6) — los diálogos se contestan por política, no a mano.
# corrida.sh responder <sesión>, invocado por el vigilante (tmux-activity-watch.sh)
# al detectar un diálogo. Decide con el registro de la corrida y la tabla de modos,
# nunca con criterio libre: confianza de carpeta de un worktree de la corrida =>
# acepta; límite de uso => conserva el modelo y marca el carril cuota; comando que
# casa una fila Aprobado => acepta, Negado => niega; la lista dura (la de
# validar_registro en lib.sh, sin duplicarla) y todo lo que no casa => no contesta
# y escala NECESITO TU RESPUESTA con el comando textual y las dos opciones.
# Relee la pantalla y exige el mismo checksum antes de mandar la tecla. Tres
# diálogos en 10 min en un CLI con cambio de modo conocido => cambia de modo en vez
# de seguir contestando. Cada decisión queda en decisiones.jsonl.
#
# Nace APAGADO: sin $CORRIDA_STATE/<id>/responder.on no manda ninguna tecla ni
# ningún mensaje; solo anota qué habría hecho. Encenderlo para una corrida real es
# decisión del dueño. La sesión que no está en un registro ABIERTO jamás se toca.
# Compatible con /bin/bash 3.2 de macOS.

# Ventana y cola normalizada: mismas reglas que el vigilante (últimas 15 líneas no
# vacías, relojes y no-ASCII fuera), para que el checksum de la relectura juzgue la
# misma pantalla que el vigilante vio.
RESP_TAIL_LINES="${RESP_TAIL_LINES:-15}"
RESP_VENTANA_SEG="${RESP_VENTANA_SEG:-600}"
resp_cola() {
  grep -v '^[[:space:]]*$' | tail -n "$RESP_TAIL_LINES" |
    LC_ALL=C sed -E 's/[0-9]+(\.[0-9]+)?[smh]//g; s/[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?//g' |
    LC_ALL=C tr -cd '\11\12\40-\176'
}
resp_sum() { cksum | awk '{ print $1 "-" $2 }'; }
resp_captura() { "$TMUX_BIN" capture-pane -p -t "$1" 2>/dev/null; }

# Firma de diálogo: la misma RE que el vigilante (ASCII, sobre la cola normalizada,
# grep -i). Las dos mitades: las preguntas medidas en los diez CLIs y la firma
# genérica de diálogo de selección (Enter confirma / Esc cancela / y/n).
RESP_APPROVAL_RE="${RESP_APPROVAL_RE:-}"
[ -n "$RESP_APPROVAL_RE" ] || RESP_APPROVAL_RE='allow once|always allow|would you like to allow|do you want to proceed|run this command\?|waiting for approval|do you trust|trust this (folder|workspace)|enter (to )?(select|confirm|continue)|esc (to )?(cancel|go back|exit)|arrow keys to navigate|[[(]y/n[])]|[(]yes/no[)]'
# Clases de diálogo (medidas 2026-09-17, spike 9.0): la confianza de carpeta de
# codex/kimi/cursor-agent y el límite de uso de codex (no es un permiso, pero
# también espera a una persona).
RESP_TRUST_RE='do you trust|trust this (folder|workspace|directory)|trust the contents'
RESP_CUOTA_RE='usage limit|approaching rate limit|keep current model|purchase more credits|out of (credits|quota)'

resp_es_dialogo() { printf '%s\n' "$1" | grep -Eqi -- "$RESP_APPROVAL_RE"; }
resp_es_confianza() { printf '%s\n' "$1" | grep -Eqi -- "$RESP_TRUST_RE"; }
resp_es_cuota() { printf '%s\n' "$1" | grep -Eqi -- "$RESP_CUOTA_RE"; }

# El comando textual del diálogo: la ÚLTIMA línea que parece una orden de shell
# (pelando los prefijos de prompt "$ " y ">") previa a la firma del diálogo; si
# ninguna lo parece, la última línea. Un CLI que conserva transcript encima del
# diálogo (claude lo hace) puede traer un comando viejo y delicado dentro de las
# 15 líneas: el comando preguntado es el de abajo, el más cercano a la pregunta
# (BRIEF-r1 PB). Una línea de ayuda ("navigate", "Esc to cancel") no empieza con
# palabra minúscula + espacio, y las opciones numeradas empiezan con dígito.
resp_comando() {
  printf '%s\n' "$1" | awk '
    { l=$0
      sub(/^[[:space:]]+/, "", l)
      while (l ~ /^[$>]/) { sub(/^[$>][[:space:]]?/, "", l); sub(/^[[:space:]]+/, "", l) }
      ult=l
      if (l ~ /^[a-z][a-z0-9_.-]* .+/) cmd=l
    }
    END { print (cmd != "" ? cmd : ult) }
  '
}

# La tabla de preaprobaciones se valida AL CARGAR: un patrón que no compila, o tan
# ancho que casa una sonda neutral (".*" sin ancla), no puede decidir nada de nada.
resp_carga_pre() { # $1 registro; 0 = cargable; imprime ROTO:<motivo> si no
  REG="$1" python3 -c '
import json,os,re,sys
try: d=json.load(open(os.environ["REG"]))
except Exception:
  print("ROTO:registro ilegible"); sys.exit(1)
sonda="zzz neutral 9x"
for p in (d.get("preaprobaciones") or []):
  if not isinstance(p,dict): continue
  pat=str(p.get("patron",""))
  try: c=re.compile(pat,re.I)
  except Exception:
    print("ROTO:no compila: "+pat); sys.exit(1)
  if c.search(sonda):
    print("ROTO:patron ancho: "+pat); sys.exit(1)
sys.exit(0)' 2>/dev/null
}

# Primera fila que casa el comando (regex search, sin distinguir mayúsculas).
resp_fila_de() { # $1 registro, $2 comando -> "Aprobado|patron" | "Negado|patron" | "NINGUNA"
  REG="$1" CMD="$2" python3 -c '
import json,os,re
try: d=json.load(open(os.environ["REG"]))
except Exception: d={}
cmd=os.environ["CMD"].lower()
for p in (d.get("preaprobaciones") or []):
  if not isinstance(p,dict) or p.get("decision") not in ("Aprobado","Negado"): continue
  pat=str(p.get("patron",""))
  try: c=re.compile(pat,re.I)
  except Exception: continue
  if c.search(cmd):
    print(p["decision"]+"|"+pat); break
else: print("NINGUNA")' 2>/dev/null
}

# Lista dura sin duplicarla: un registro sintético VÁLIDO por derecho propio
# (BRIEF-r2 QD) cuya única preaprobación es ESTE comando con decisión Aprobado.
# Tres salidas: 0 = el validador lo tacha de lista dura aprobada (inaprobable
# por cualquier tabla); 1 = el registro es válido y el comando no cae (limpio);
# 2 = el validador falló por otra razón y NO SE PUDO COMPROBAR — el llamador lo
# trata como escala, jamás como aceptación.
resp_lista_dura() { # $1 comando; 0 = lista dura, 1 = limpio, 2 = sin comprobar
  local sint salida r
  sint="$(mktemp)" || return 2
  CMD="$1" SAL="$sint" python3 -c '
import json,os
d={"schema":"corrida.v1","id":"lista-dura","runbook":"docs/runbooks/autopilot-fase9.md",
   "vigia":"claw","simulacro":True,"canal":{"cron":"sonda","destino":"sonda"},
   "cli_modos":"sonda","cron_vigia_id":"sonda","inicio":"2026-09-19T00:00:00+0000",
   "timebox_horas":6,"sesiones":[],
   "preaprobaciones":[{"patron":os.environ["CMD"],"decision":"Aprobado"}],
   "estado":"abierta"}
open(os.environ["SAL"],"w").write(json.dumps(d,indent=1)+chr(10))' 2>/dev/null \
    || { rm -f "$sint"; return 2; }
  salida="$(validar_registro "$sint" 2>/dev/null)"
  r=$?
  rm -f "$sint"
  [ "$r" -eq 0 ] && return 1
  case "$salida" in *"lista dura aprobada"*) return 0;; esac
  return 2
}

# Las teclas y el cambio de modo vienen de la tabla (dato): solo token por token
# validado, nada viaja a un sh. Una tecla es un carácter o un nombre de tecla de
# tmux; una celda puede traer una secuencia ("2 Enter").
resp_teclas_ok() { # $1 celda; 0 = todos los tokens usables
  local t
  [ -n "$1" ] || return 1
  for t in $1; do
    case "$t" in
      [A-Za-z0-9]) ;;
      Enter|Escape|Esc|Tab|Space|Up|Down|Left|Right) ;;
      *) return 1;;
    esac
  done
  return 0
}
resp_manda_teclas() { # $1 sesión, $2 celda; 0 = todo enviado
  local t rc=0
  for t in $2; do
    "$TMUX_BIN" send-keys -t "$1" "$t" 2>/dev/null || rc=1
  done
  return "$rc"
}
resp_cambio_ok() { # $1 celda de cambio de modo; 0 = usable
  [ -n "$1" ] || return 1
  case "$1" in -*|*[!A-Za-z0-9\ _./=-]*) return 1;; esac
  return 0
}

# TOCTOU: antes de cada tecla se relee la pantalla y se exige el mismo checksum de
# la cola normalizada; si cambió, no se manda nada.
resp_relee() { # $1 sesión, $2 checksum de la primera lectura; 0 = pantalla intacta
  local c
  c="$(resp_captura "$1" | resp_cola | resp_sum)"
  [ -n "$c" ] && [ "$c" = "$2" ]
}

# Normalización de una ruta con la MISMA pipa de la cola: la ruta del registro y
# la del panel se comparan contra rutas extraídas de una pantalla ya normalizada.
resp_norm_ruta() {
  printf '%s\n' "$1" |
    LC_ALL=C sed -E 's/[0-9]+(\.[0-9]+)?[smh]//g; s/[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?//g' |
    LC_ALL=C tr -cd '\11\12\40-\176'
}

resp_anota() { # $1 id, $2 clase, $3 decisión, $4 comando, $5 teclas, $6 motivo,
               # $7 enviado(0/1), $8 sesión, $9 cli -> una línea en decisiones.jsonl
  DEC_DIR="$CORRIDA_STATE/$1" A_CLASE="$2" A_DEC="$3" A_CMD="$4" A_TEC="$5" \
  A_MOT="$6" A_ENV="$7" A_SES="$8" A_CLI="$9" python3 -c '
import json,os,time
d={"ts":int(time.time()),"sesion":os.environ["A_SES"],"cli":os.environ["A_CLI"],
   "clase":os.environ["A_CLASE"],"decision":os.environ["A_DEC"],
   "comando":os.environ["A_CMD"],"teclas":os.environ["A_TEC"],
   "motivo":os.environ["A_MOT"],"enviado":os.environ["A_ENV"]=="1"}
p=os.path.join(os.environ["DEC_DIR"],"decisiones.jsonl")
open(p,"a").write(json.dumps(d)+chr(10))
try: os.chmod(p,0o600)
except Exception: pass' 2>/dev/null
}

resp_recientes() { # $1 id, $2 sesión, $3 ventana en segundos -> diálogos anotados dentro
  DEC="$CORRIDA_STATE/$1/decisiones.jsonl" SES="$2" VENT="$3" python3 -c '
import json,os,time
n=0
try: lin=open(os.environ["DEC"]).read().splitlines()
except Exception: lin=[]
corte=time.time()-float(os.environ["VENT"])
for l in lin:
  try: d=json.loads(l)
  except Exception: continue
  ts=d.get("ts")
  if d.get("sesion")==os.environ["SES"] and isinstance(ts,(int,float)) and not isinstance(ts,bool) and ts>=corte:
    n+=1
print(n)' 2>/dev/null
}

resp_marca_cuota() { # $1 registro, $2 sesión: cuota=true en su sesión, bajo lock
  if ! lock_tomar "$1"; then
    echo "responder: el lock del registro no cede; la sesión no quedó marcada cuota" >&2
    return 1
  fi
  CORR_SES="$2" registro_escribir "$1" "
for s in d['sesiones']:
    if s.get('nombre')==os.environ['CORR_SES']: s['cuota']=True
" || { lock_soltar "$1"; return 1; }
  lock_soltar "$1"
}

# La escala sale por el contrato de siempre (seguimiento.v1): etiqueta NECESITO TU
# RESPUESTA, en lenguaje de usuario, con las dos opciones y el comando textual como
# referencia al final de la línea 4 (el validador corta el marcador Comando: antes
# de revisar la jerga, que en un comando es inevitable).
resp_escala() { # $1 id, $2 partes, $3 sesión, $4 referencia textual (<=200 chars)
  local ref="$4"
  [ "${#ref}" -gt 200 ] && ref="${ref:0:200}"
  corrida_mensaje "$1" "NECESITO TU RESPUESTA" "0 de $2 partes terminadas" \
    "Una parte de la corrida quedó esperando una respuesta que la política no da sola." \
    "Esa parte no avanza hasta tener la respuesta; el resto sigue como estaba." \
    "Di sí para aceptar lo que la sesión pide o no para rechazarlo. Comando: $ref"
}

corrida_responder() {
  local ses="${1:-}"
  case "$ses" in ''|*[!A-Za-z0-9._-]*)
    echo "responder: sesión inválida: $ses" >&2; return 2;; esac

  # La sesión -> el registro ABIERTO que la lista entre sus sesiones. Sin registro
  # que la reclame, jamás se toca (ni teclas, ni anotaciones, ni mensajes).
  local hallado
  hallado="$(CORRIDA_STATE="$CORRIDA_STATE" RESP_SES="$ses" python3 -c '
import json,os,glob,sys
try: bases=sorted(glob.glob(os.environ["CORRIDA_STATE"]+"/*/registro.json"))
except Exception: bases=[]
for p in bases:
  try: d=json.load(open(p))
  except Exception: continue
  if d.get("estado")!="abierta": continue
  ss=d.get("sesiones")
  if not isinstance(ss,list): continue
  for s in ss:
    if isinstance(s,dict) and s.get("nombre")==os.environ["RESP_SES"]:
      print((d.get("id") or "")+chr(9)+p); sys.exit(0)
' 2>/dev/null)"
  [ -n "$hallado" ] || { echo "responder: $ses no está en ninguna corrida abierta; no se toca" >&2; return 1; }
  local id="${hallado%%$'\t'*}" reg="${hallado#*$'\t'}"

  # Su sesión dentro del registro: CLI, directorio y cuántas partes son.
  local info
  info="$(RESP_REG="$reg" RESP_SES="$ses" python3 -c '
import json,os
try: d=json.load(open(os.environ["RESP_REG"]))
except Exception: d={}
for s in (d.get("sesiones") or []):
  if isinstance(s,dict) and s.get("nombre")==os.environ["RESP_SES"]:
    print("%s\t%s\t%d"%(s.get("cli") or "",s.get("dir") or "",len(d.get("sesiones") or [])))
    break' 2>/dev/null)"
  [ -n "$info" ] || { echo "responder: $ses desapareció del registro de $id" >&2; return 1; }
  local cli dir_ses nses
  IFS=$'\t' read -r cli dir_ses nses <<EOF
$info
EOF

  local tabla motivo
  tabla="$(json_campo "$reg" cli_modos)"
  [ -n "$tabla" ] || tabla="$HOME/bin/cli-modos.tsv"
  [ -r "$tabla" ] || { echo "responder: sin tabla de modos legible: $tabla" >&2; return 2; }
  motivo="$(resp_carga_pre "$reg")"
  if [ "$?" -ne 0 ]; then
    echo "responder: la tabla de preaprobaciones de $id no se carga ($motivo); no se contesta nada" >&2
    return 2
  fi

  # La fila del CLI en la tabla de modos: cambio de modo, tecla que acepta, tecla
  # que niega. unknown y -- son "sin medir": esa vía no se usa.
  local fila cambio="" acepta="" niega=""
  fila="$(awk -F'\t' -v c="$cli" '$1==c && $1 !~ /^#/ {print $5"\t"$6"\t"$7; exit}' "$tabla")"
  if [ -n "$fila" ]; then
    IFS=$'\t' read -r cambio acepta niega <<EOF
$fila
EOF
  fi
  case "$cambio" in unknown|--|"") cambio="";; esac
  case "$acepta"  in unknown|--|"") acepta="";;  esac
  case "$niega"   in unknown|--|"") niega="";;   esac

  local pantalla cola1 cksum1
  pantalla="$(resp_captura "$ses")"
  [ -n "$pantalla" ] || { echo "responder: sin pantalla de $ses" >&2; return 1; }
  # El checksum y la relectura ven el MISMO byte stream: la cola se guarda solo
  # para leerla, el checksum sale de la misma pipa (con su salto final) que la de
  # resp_relee — una sustitución de comando se come el salto final y volaria la
  # comparacion.
  cola1="$(printf '%s\n' "$pantalla" | resp_cola)"
  cksum1="$(printf '%s\n' "$pantalla" | resp_cola | resp_sum)"
  resp_es_dialogo "$cola1" || { echo "responder: $ses no muestra un diálogo" >&2; return 1; }

  local encendido=0
  [ -e "$CORRIDA_STATE/$id/responder.on" ] && encendido=1

  # Clasificación del diálogo y decisión por política.
  local clase comando="" decision teclas="" ref="" esca_motivo=""
  if resp_es_confianza "$cola1"; then
    clase=confianza
    # La confianza solo se aprueba para una carpeta DE la corrida: sin ruta en
    # pantalla, o la del registro / la del panel; una ruta ajena escala.
    local r cwd="" okruta=1
    while IFS= read -r r; do
      if [ -z "$r" ] || [ "$r" = "/" ]; then continue; fi
      [ -n "$cwd" ] || cwd="$("$TMUX_BIN" display-message -p -t "$ses" '#{pane_current_path}' 2>/dev/null)"
      if [ "$r" != "$(resp_norm_ruta "$dir_ses")" ] && [ "$r" != "$(resp_norm_ruta "$cwd")" ]; then
        okruta=0; ref="$r"; break
      fi
    done <<EOF
$(printf '%s\n' "$cola1" | LC_ALL=C grep -oE '/[A-Za-z0-9_./-]+' | sort -u)
EOF
    if [ "$okruta" -eq 1 ]; then
      decision=acepta; teclas="$acepta"
    else
      decision=escala; esca_motivo="confianza en una carpeta ajena a la corrida"
    fi
  elif resp_es_cuota "$cola1"; then
    clase=cuota
    comando="límite de uso"
    decision=niega; teclas="$niega"   # niega el cambio: conserva el modelo
    ref="límite de uso"
  else
    clase=comando
    comando="$(resp_comando "$cola1")"
    ref="$comando"
    # 0 = lista dura, 2 = no se pudo comprobar (fail-closed): ambas escalan.
    local lh=0
    resp_lista_dura "$comando" || lh=$?
    if [ "$lh" -eq 0 ]; then
      decision=escala; esca_motivo="lista dura: ninguna tabla lo aprueba"
    elif [ "$lh" -eq 2 ]; then
      decision=escala; esca_motivo="no se pudo comprobar la lista dura"
    else
      local fila_pre
      fila_pre="$(resp_fila_de "$reg" "$comando")"
      case "${fila_pre%%|*}" in
        Aprobado) decision=acepta; teclas="$acepta";;
        Negado)   decision=niega;  teclas="$niega";;
        *)        decision=escala; esca_motivo="sin fila que case en la tabla del registro";;
      esac
    fi
  fi

  # Tecla sin medir: esa vía no se usa; se escala en vez de inventar.
  if [ "$decision" != "escala" ] && ! resp_teclas_ok "$teclas"; then
    decision=escala
    esca_motivo="tecla sin medir en la tabla de modos"
  fi

  if [ "$decision" = "escala" ]; then
    local envio=0
    if [ "$encendido" -eq 1 ]; then
      resp_escala "$id" "$nses" "$ses" "$ref" && envio=1
    fi
    resp_anota "$id" "$clase" escala "$comando" "" "$esca_motivo" "$envio" "$ses" "$cli"
    echo "responder: $ses escala ($esca_motivo)" >&2
    return 1
  fi

  # Tres diálogos en 10 min en un CLI con cambio de modo conocido — y que la
  # política SÍ contestaría (BRIEF-r2 QB): la ráfaga no pisa a la política, un
  # tercer diálogo de lista dura, sin fila o con teclas sin medir escala igual.
  # En vez de seguir contestando de uno en uno, se cambia de modo (contando las
  # propias anotaciones de esta sesión en decisiones.jsonl).
  local recientes
  recientes="$(resp_recientes "$id" "$ses" "$RESP_VENTANA_SEG")"
  if [ "${recientes:-0}" -ge 2 ] 2>/dev/null && resp_cambio_ok "$cambio"; then
    if [ "$encendido" -eq 0 ]; then
      resp_anota "$id" modo modo "" "$cambio + Enter" "apagado: no se mandó" 0 "$ses" "$cli"
      echo "responder: $ses lleva tres diálogos en 10 min; apagado, no se cambió de modo" >&2
      return 1
    fi
    if ! resp_relee "$ses" "$cksum1"; then
      resp_anota "$id" pantalla nada "" "$cambio + Enter" "la pantalla cambió entre lectura y envío" 0 "$ses" "$cli"
      echo "responder: la pantalla de $ses cambió antes del cambio de modo; no se mandó nada" >&2
      return 1
    fi
    # BRIEF-r2 QC: un send-keys que falla no es un cambio de modo: se comprueban
    # ambos rc, se anota el fallo y se escala (el diálogo sigue sin atender).
    local rcm1=0 rcm2=0 envio_m=0
    "$TMUX_BIN" send-keys -t "$ses" -l "$cambio" 2>/dev/null || rcm1=1
    "$TMUX_BIN" send-keys -t "$ses" Enter 2>/dev/null || rcm2=1
    if [ "$rcm1" -ne 0 ] || [ "$rcm2" -ne 0 ]; then
      resp_escala "$id" "$nses" "$ses" "$ref" && envio_m=1
      resp_anota "$id" modo escala "$comando" "$cambio + Enter" "falló el envío del cambio de modo" "$envio_m" "$ses" "$cli"
      echo "responder: no se pudo mandar el cambio de modo a $ses; se escala" >&2
      return 1
    fi
    resp_anota "$id" modo modo "" "$cambio + Enter" "" 1 "$ses" "$cli"
    echo "responder: $ses cambió de modo ($cambio) tras tres diálogos en 10 min" >&2
    return 0
  fi

  if [ "$encendido" -eq 0 ]; then
    resp_anota "$id" "$clase" "$decision" "$comando" "$teclas" "apagado: no se mandó" 0 "$ses" "$cli"
    echo "responder: apagado; $ses habría $decision ($teclas)" >&2
    return 1
  fi

  if ! resp_relee "$ses" "$cksum1"; then
    resp_anota "$id" pantalla nada "$comando" "$teclas" "la pantalla cambió entre lectura y envío" 0 "$ses" "$cli"
    echo "responder: la pantalla de $ses cambió entre lectura y envío; no se mandó nada" >&2
    return 1
  fi

  if ! resp_manda_teclas "$ses" "$teclas"; then
    resp_anota "$id" "$clase" "$decision" "$comando" "$teclas" "falló el envío de la tecla" 0 "$ses" "$cli"
    echo "responder: no se pudo mandar la tecla a $ses" >&2
    return 1
  fi

  if [ "$clase" = "cuota" ]; then
    resp_marca_cuota "$reg" "$ses" \
      || echo "responder: la sesión $ses no quedó marcada cuota en el registro" >&2
  fi
  resp_anota "$id" "$clase" "$decision" "$comando" "$teclas" "" 1 "$ses" "$cli"
  echo "responder: $ses $decision ($clase)" >&2
  return 0
}
