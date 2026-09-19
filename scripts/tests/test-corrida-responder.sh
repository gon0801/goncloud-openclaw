#!/bin/bash
# Prueba de la tarea 9.6 "Diálogos por política, no a mano": corrida.sh responder
# <sesión> decide con la tabla del registro qué tecla mandar (o escalar) cuando un
# CLI de la corrida queda esperando a una persona. Corre contra un servidor tmux
# PROPIO (-L, nunca el del usuario), un registro de corrida de mentira bajo un
# CORRIDA_STATE temporal y un stub de openclaw que solo anota sus argumentos:
# ninguna prueba manda un Telegram real ni despierta a un agente vivo.
# Cubre el DoD 9.6: confianza de carpeta de la corrida => acepta; límite de uso =>
# conserva el modelo y marca cuota; fila Aprobado/Negado => acepta/niega; lista
# dura (rm -rf, push a main) => escala aunque haya fila Aprobado; sin fila o tecla
# sin medir => escala; patrón ancho => rechazado al cargar; pantalla que cambia
# entre lectura y envío => no manda nada; tres diálogos en 10 min con cambio de
# modo conocido => cambia de modo; sesión fuera de un registro abierto => jamás se
# toca; nace apagado (sin responder.on registra qué habría hecho y no manda nada).
# Uso: bash scripts/tests/test-corrida-responder.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
RESP=scripts/mac/corrida/responder.sh
FIXD="$PWD/scripts/tests/fixtures/dialogos"
[ -f "$CORR" ] || fail "falta $CORR"
[ -f "$RESP" ] || fail "falta $RESP"
[ -f "$FIXD/confianza.txt" ] || fail "falta el fixture $FIXD/confianza.txt"
[ -f "$FIXD/permiso-push.txt" ] || fail "falta el fixture $FIXD/permiso-push.txt"

# (0) Parsea con el bash 3.2 del sistema y con el de homebrew; argumentos obvios.
/bin/bash -n "$RESP" || fail "$RESP no parsea con /bin/bash"
if [ -x /opt/homebrew/bin/bash ]; then
  /opt/homebrew/bin/bash -n "$RESP" || fail "$RESP no parsea con /opt/homebrew/bin/bash"
fi
bash "$CORR" responder >/dev/null 2>&1; [ $? -eq 2 ] || fail "responder sin sesión debe salir 2"
bash "$CORR" responder 'x;y' >/dev/null 2>&1; [ $? -eq 2 ] || fail "responder debe rechazar un nombre de sesión con ;"
echo "ok (0): responder.sh parsea (bash 3.2 y homebrew) y rechaza sesión vacía o inválida"

TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba de diálogos"

T=$(mktemp -d) || exit 1
L="resp$$"
# Cláusula (a) de la fase: no se borra nada de lo creado; el trap solo apaga el
# servidor tmux propio. El directorio $T queda y se declara en el reporte.
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null' EXIT
mkdir -p "$T/bin" "$T/corridas" "$T/work" "$T/pantallas"
WORK="$(CDPATH= cd -P -- "$T/work" && pwd)"

# Stub de openclaw: anota y contesta ok; jamás un Telegram real.
LLAMADAS="$T/llamadas.log"; : >"$LLAMADAS"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
printf 'OPENCLAW %s\n' "\$*" >> "$LLAMADAS"
exit 0
STUB
chmod +x "$T/bin/openclaw"

# Shim de tmux: anota cada llamada del responder y ejecuta en el servidor propio.
# Las teclas se compruean por el registro (send-keys -t <sesión> <tecla>).
TMUX_LOG="$T/tmux.log"; : >"$TMUX_LOG"
cat >"$T/bin/tmux" <<STUB
#!/bin/sh
printf '%s\n' "TMUX \$*" >> "$TMUX_LOG"
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux"

export CORRIDA_STATE="$T/corridas" OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux"

# Tabla de modos propia de la prueba, con las teclas medidas en el spike 9.0
# (la del repo sigue tal cual: unknown => esa vía no se usa y escala).
{
  printf 'glm\tglm\t--mode yolo\tyolo\t/mode yolo\ty\tn\n'
  printf 'claude\tclaude\tunknown\tunknown\tunknown\t1\t2\n'
  printf 'codex\tcodex\tunknown\tunknown\tunknown\t1\t2\n'
  printf 'kimi\tkimi\tunknown\tunknown\tunknown\tEnter\tEscape\n'
  printf 'cursor-agent\tcursor-agent\t-f --trust\tunknown\tunknown\ta\tq\n'
  printf 'deepseek\tdeepseek\tunknown\tunknown\tunknown\tunknown\tunknown\n'
} >"$T/modos.tsv"

seses() { # pares nombre cli -> lista json de sesiones (dir = $WORK)
  local out="[" first=1 n c
  while [ $# -ge 2 ]; do
    n="$1"; c="$2"; shift 2
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    out="$out{\"nombre\":\"$n\",\"rol\":\"carril\",\"cli\":\"$c\",\"dueno\":\"p\",\"dir\":\"$WORK\"}"
  done
  printf '%s]' "$out"
}
pres() { # pares patron decisión -> lista json de preaprobaciones
  local out="[" first=1 p d
  while [ $# -ge 2 ]; do
    p="$1"; d="$2"; shift 2
    [ "$first" -eq 1 ] || out="$out,"
    first=0
    out="$out{\"patron\":\"$p\",\"decision\":\"$d\"}"
  done
  printf '%s]' "$out"
}
abrir() { # $1 id, $2 sesiones json, $3 preaprobaciones json
  RID="$1" RSES="$2" RPRE="$3" RMODOS="$T/modos.tsv" \
  RREG="$CORRIDA_STATE/$1/registro.json" python3 - <<'PY'
import json,os
E=os.environ
d={'schema':'corrida.v1','id':E['RID'],'runbook':'docs/runbooks/autopilot-fase9.md','vigia':'claw',
   'simulacro':True,'canal':{'cron':'verif-sync-repos','destino':'DESTINO-9X'},
   'cli_modos':E['RMODOS'],'cron_vigia_id':'cron-falso','inicio':'2026-09-19T09:00:00+0200',
   'timebox_horas':6,'sesiones':json.loads(E['RSES']),'preaprobaciones':json.loads(E['RPRE']),
   'estado':'abierta'}
os.makedirs(os.path.dirname(E['RREG']),exist_ok=True)
open(E['RREG'],'w').write(json.dumps(d,indent=1)+chr(10))
os.chmod(E['RREG'],0o600)
PY
}
encender() { : >"$CORRIDA_STATE/$1/responder.on"; }

# Un panel que pinta una pantalla fija y espera: la pantalla no se mueve sola, así
# que la relectura del responder solo cambia si el test la cambia.
pan() { # $1 sesión, $2 archivo de pantalla
  "$TM_REAL" -L "$L" new-session -d -s "$1" -x 100 -y 30 -c "$WORK" "cat '$2'; exec cat" \
    || fail "no se pudo crear la sesión $1"
}
espera() { # $1 sesión, $2 texto que debe verse
  local i=0
  while [ "$i" -lt 50 ]; do
    "$TM_REAL" -L "$L" capture-pane -p -t "$1" 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "la pantalla de $1 no mostró '$2' en 5 s"
}
corre() { # $1 sesión: corre el responder y deja rc en $?
  bash "$CORR" responder "$1" >/dev/null 2>&1
}
udec() { tail -n 1 "$CORRIDA_STATE/$1/decisiones.jsonl" 2>/dev/null; }
jcampo() { # $1 campo, $2 json -> valor plano
  JF="$1" python3 -c '
import json,os,sys
try: d=json.loads(sys.stdin.read() or "{}")
except Exception: d={}
v=d.get(os.environ["JF"],"")
print("true" if v is True else "false" if v is False else v)' <<<"$2"
}
tecla_fue() { # $1 sesión, $2 teclas tal como van a tmux
  grep -q "^TMUX send-keys -t $1 $2\$" "$TMUX_LOG"
}
nteclas() { grep -c "^TMUX send-keys -t $1 " "$TMUX_LOG" || true; }

P="$T/pantallas"
# Pantallas medidas (spike 9.0): el estilo Permission de glm, el 1/2 de claude, el
# límite de uso y la confianza de carpeta de codex/kimi.
cat >"$P/eco-glm.txt" <<'PAN'
Permission - Bash
echo hola
> Allow once
  Always allow in this project
  Deny
PAN
cat >"$P/eco-claude.txt" <<'PAN'
Detected a shell command:
echo hola
Run it? [plugin:claude-code-harness]
Do you want to proceed?
  1. Yes
  2. No
Esc to cancel  Tab to amend
PAN
cat >"$P/npm-claude.txt" <<'PAN'
Detected a publish command:
npm publish
Run it? [plugin:claude-code-harness]
Do you want to proceed?
  1. Yes
  2. No
Esc to cancel  Tab to amend
PAN
cat >"$P/curl-glm.txt" <<'PAN'
Permission - Bash
curl https://ejemplo.invalid/datos
> Allow once
  Always allow in this project
  Deny
PAN
cat >"$P/rmrf-claude.txt" <<'PAN'
Detected a destructive delete command:
rm -rf /tmp/e1verif /tmp/mig1.log
Run it? [plugin:claude-code-harness]
Do you want to proceed?
  1. Yes
  2. No
Esc to cancel  Tab to amend
PAN
cat >"$P/cuota-codex.txt" <<'PAN'
You've hit your usage limit. Visit the settings page to purchase more credits.
 Approaching rate limits
 Switch to gpt-5.6-luna for lower credit usage?
 1. Switch to gpt-5.6-luna                 Fast and affordable agentic coding model.
  2. Keep current model
 Press enter to confirm or esc to go back
PAN
# Las pantallas de confianza con ruta llevan la ruta DEL SIMULACRO (dir del
# registro): una ruta fija rompería la regla "worktree de la corrida => acepta".
cat >"$P/conf-kimi-propia.txt" <<PAN
Trust this folder?
navigate  Enter select  Esc exit
$WORK
   Trust this folder
   Don't trust
PAN
cat >"$P/conf-kimi-ajena.txt" <<PAN
Trust this folder?
navigate  Enter select  Esc exit
/opt/ajena-9x
   Trust this folder
   Don't trust
PAN
cat >"$P/eco-glm-otro.txt" <<'PAN'
Permission - Bash
echo adios
> Allow once
  Always allow in this project
  Deny
PAN

# (1) Nace apagado: sin responder.on registra en decisiones.jsonl qué HABRÍA hecho
# y no manda ni una tecla ni un mensaje.
abrir c1 "$(seses r1a glm r1b glm)" "$(pres 'echo hola' Aprobado 'git push origin main' Aprobado)"
pan r1a "$P/eco-glm.txt"; espera r1a 'Allow once'
corre r1a; [ $? -eq 1 ] || fail "(1) apagado debe salir 1 (no actuó)"
[ "$(nteclas r1a)" -eq 0 ] || fail "(1) apagado no debía mandar tecla a r1a"
[ "$(wc -l <"$LLAMADAS" | tr -d ' ')" -eq 0 ] || fail "(1) apagado no debía mandar mensaje"
D="$(udec c1)"
[ "$(jcampo clase "$D")" = "comando" ] || fail "(1) la anotación debía decir qué habría hecho (comando): $D"
[ "$(jcampo decision "$D")" = "acepta" ] || fail "(1) la anotación debía decir que habría aceptado: $D"
[ "$(jcampo enviado "$D")" = "false" ] || fail "(1) la anotación debía decir que no envió: $D"
pan r1b "$FIXD/permiso-push.txt"; espera r1b 'Allow once'
corre r1b; [ $? -eq 1 ] || fail "(1) apagado ante la lista dura debe salir 1"
D="$(udec c1)"
[ "$(jcampo decision "$D")" = "escala" ] || fail "(1) habría escalado el push a main: $D"
[ "$(jcampo enviado "$D")" = "false" ] || fail "(1) apagado no manda el mensaje de escala: $D"
[ "$(wc -l <"$LLAMADAS" | tr -d ' ')" -eq 0 ] || fail "(1) apagado no debía mandar mensaje (ni el de escala)"
permiso() { if [ "$(uname)" = "Darwin" ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
[ "$(permiso "$CORRIDA_STATE/c1/decisiones.jsonl")" = "600" ] || fail "(1) decisiones.jsonl debe quedar 600"
echo "ok (1): sin responder.on registra qué habría hecho (enviado=false) y no manda teclas ni mensajes"

# (2) Confianza de carpeta de la corrida => acepta. El fixture del simulacro no
# trae ruta absoluta (los dirs del simulacro son dinámicos) y la tecla sale de la
# tabla: cursor-agent => a.
abrir c2 "$(seses r2 cursor-agent)" "[]"
encender c2
pan r2 "$FIXD/confianza.txt"; espera r2 'Trust this workspace'
corre r2; [ $? -eq 0 ] || fail "(2) confianza de la corrida debía contestar (rc 0)"
tecla_fue r2 a || fail "(2) la tecla de aceptar de cursor-agent es a: $(grep 'send-keys' "$TMUX_LOG")"
D="$(udec c2)"
[ "$(jcampo clase "$D")" = "confianza" ] || fail "(2) clase confianza: $D"
[ "$(jcampo decision "$D")" = "acepta" ] || fail "(2) decisión acepta: $D"
[ "$(jcampo enviado "$D")" = "true" ] || fail "(2) enviado true: $D"
echo "ok (2): fixture confianza.txt (sin ruta) => acepta con la tecla de la tabla"

# (3) Lista dura: ni con fila Aprobado. push a main y rm -rf escalan con el
# comando textual y las dos opciones, sin mandar tecla.
abrir c3 "$(seses r3 glm r3b claude)" "$(pres 'git push origin main' Aprobado 'rm -rf' Aprobado)"
encender c3
pan r3 "$FIXD/permiso-push.txt"; espera r3 'Allow once'
: >"$LLAMADAS"
corre r3; [ $? -eq 1 ] || fail "(3) la lista dura no se contesta (rc 1)"
[ "$(nteclas r3)" -eq 0 ] || fail "(3) ningún push a main se contesta con tecla"
grep -qF 'NECESITO TU RESPUESTA' "$LLAMADAS" || fail "(3) debía escalar NECESITO TU RESPUESTA: $(cat "$LLAMADAS")"
grep -qF 'Comando: git push origin main' "$LLAMADAS" || fail "(3) la escala debe citar el comando textual: $(cat "$LLAMADAS")"
grep -qF '0 de 2 partes terminadas' "$LLAMADAS" || fail "(3) la escala habla de partes de la corrida: $(cat "$LLAMADAS")"
D="$(udec c3)"
[ "$(jcampo decision "$D")" = "escala" ] || fail "(3) decisión escala: $D"
case "$(jcampo motivo "$D")" in *lista\ dura*) ;; *) fail "(3) el motivo nombra la lista dura: $D";; esac
pan r3b "$P/rmrf-claude.txt"; espera r3b 'Do you want to proceed?'
: >"$LLAMADAS"
corre r3b; [ $? -eq 1 ] || fail "(3b) rm -rf con fila Aprobado no se contesta"
[ "$(nteclas r3b)" -eq 0 ] || fail "(3b) ningún rm -rf se contesta con tecla"
grep -qF 'NECESITO TU RESPUESTA' "$LLAMADAS" || fail "(3b) rm -rf debía escalar: $(cat "$LLAMADAS")"
echo "ok (3): push a main y rm -rf escalan aunque el registro los traiga Aprobados"

# (4) Comandos por tabla: Aprobado => acepta, Negado => niega, sin fila => escala.
abrir c4 "$(seses r4a claude r4b claude r4c glm r4d claude)" "$(pres 'echo hola' Aprobado 'npm publish' Negado)"
encender c4
pan r4a "$P/eco-claude.txt"; espera r4a 'Do you want to proceed?'
corre r4a; [ $? -eq 0 ] || fail "(4) comando Aprobado debía contestar"
tecla_fue r4a 1 || fail "(4) la tecla de aceptar de claude es 1: $(grep 'send-keys -t r4a' "$TMUX_LOG")"
D="$(udec c4)"
[ "$(jcampo clase "$D")" = "comando" ] && [ "$(jcampo decision "$D")" = "acepta" ] \
  || fail "(4) clase comando, decisión acepta: $D"
pan r4b "$P/npm-claude.txt"; espera r4b 'npm publish'
corre r4b; [ $? -eq 0 ] || fail "(4) comando Negado también se contesta (niega)"
tecla_fue r4b 2 || fail "(4) la tecla de negar de claude es 2: $(grep 'send-keys -t r4b' "$TMUX_LOG")"
D="$(udec c4)"
[ "$(jcampo decision "$D")" = "niega" ] || fail "(4) decisión niega: $D"
pan r4c "$P/curl-glm.txt"; espera r4c 'Allow once'
: >"$LLAMADAS"
corre r4c; [ $? -eq 1 ] || fail "(4) sin fila que case no se contesta"
[ "$(nteclas r4c)" -eq 0 ] || fail "(4) lo que no casa ninguna tabla no recibe tecla"
grep -qF 'NECESITO TU RESPUESTA' "$LLAMADAS" || fail "(4) sin fila => escala: $(cat "$LLAMADAS")"
grep -qF 'Comando: curl https://ejemplo.invalid/datos' "$LLAMADAS" \
  || fail "(4) la escala cita el comando que no casa: $(cat "$LLAMADAS")"
# (4d) BRIEF-r1 PB: un CLI que conserva transcript encima del diálogo (claude lo
# hace) puede traer un comando VIEJO y delicado dentro de las 15 líneas; la
# decisión — incluida la lista dura — debe tomarse sobre el comando del diálogo
# (el ÚLTIMO tipo comando), no sobre el de arriba.
cat >"$P/transcript-claude.txt" <<'PAN'
$ rm -rf /tmp/viejo
Detected a shell command:
echo hola
Run it? [plugin:claude-code-harness]
Do you want to proceed?
  1. Yes
  2. No
Esc to cancel  Tab to amend
PAN
pan r4d "$P/transcript-claude.txt"; espera r4d 'Do you want to proceed?'
corre r4d; [ $? -eq 0 ] || fail "(4d) debía decidir sobre el comando del diálogo (echo hola, Aprobado)"
tecla_fue r4d 1 || fail "(4d) la tecla de aceptar de claude es 1: $(grep 'send-keys -t r4d' "$TMUX_LOG")"
D="$(udec c4)"
[ "$(jcampo comando "$D")" = "echo hola" ] || fail "(4d) el comando anotado debe ser el del diálogo, no el viejo de arriba: $D"
grep -q '"comando": "rm -rf /tmp/viejo"' "$CORRIDA_STATE/c4/decisiones.jsonl" \
  && fail "(4d) ningún rm -rf viejo del transcript debe decidir nada"
echo "ok (4d): con transcript encima, decide sobre el comando del diálogo (el último), no sobre el viejo"

# (5) Límite de uso: conserva el modelo (tecla de negar) y marca el carril cuota.
abrir c5 "$(seses r5 codex)" "[]"
encender c5
pan r5 "$P/cuota-codex.txt"; espera r5 'Keep current model'
corre r5; [ $? -eq 0 ] || fail "(5) el límite de uso se contesta (conserva el modelo)"
tecla_fue r5 2 || fail "(5) conservar el modelo de codex es la opción 2: $(grep 'send-keys -t r5' "$TMUX_LOG")"
D="$(udec c5)"
[ "$(jcampo clase "$D")" = "cuota" ] || fail "(5) clase cuota: $D"
grep -q '"cuota": true' "$CORRIDA_STATE/c5/registro.json" || fail "(5) el registro debe marcar la sesión cuota"
grep -q '"nombre": "r5"' "$CORRIDA_STATE/c5/registro.json" || fail "(5) el registro conserva la sesión"
echo "ok (5): límite de uso => niega el cambio de modelo y marca cuota en el registro"

# (6) Confianza con ruta: la del registro (worktree de la corrida) => acepta; una
# ruta ajena => escala sin tocar nada.
abrir c6 "$(seses r6a kimi r6b kimi)" "[]"
encender c6
pan r6a "$P/conf-kimi-propia.txt"; espera r6a 'Trust this folder'
corre r6a; [ $? -eq 0 ] || fail "(6) confianza en la carpeta de la corrida => acepta"
tecla_fue r6a Enter || fail "(6) la tecla de aceptar de kimi es Enter: $(grep 'send-keys -t r6a' "$TMUX_LOG")"
pan r6b "$P/conf-kimi-ajena.txt"; espera r6b 'Trust this folder'
: >"$LLAMADAS"
corre r6b; [ $? -eq 1 ] || fail "(6) confianza en carpeta ajena no se acepta"
[ "$(nteclas r6b)" -eq 0 ] || fail "(6) carpeta ajena: ninguna tecla"
grep -qF 'NECESITO TU RESPUESTA' "$LLAMADAS" || fail "(6) carpeta ajena => escala: $(cat "$LLAMADAS")"
echo "ok (6): confianza nombra la carpeta de la corrida => acepta; ajena => escala"

# (7) Sesión que no está en un registro abierto: jamás se toca.
pan r7 "$P/eco-glm.txt"; espera r7 'Allow once'
antes=$(cat "$CORRIDA_STATE"/*/decisiones.jsonl 2>/dev/null | wc -l | tr -d ' ')
llamas_antes=$(wc -l <"$LLAMADAS" | tr -d ' ')
corre r7; [ $? -eq 1 ] || fail "(7) sesión sin registro: no actúa (rc 1)"
[ "$(nteclas r7)" -eq 0 ] || fail "(7) sesión sin registro: ninguna tecla"
despues=$(cat "$CORRIDA_STATE"/*/decisiones.jsonl 2>/dev/null | wc -l | tr -d ' ')
[ "$despues" -eq "$antes" ] || fail "(7) sesión sin registro: ni anota ($antes -> $despues)"
[ "$(wc -l <"$LLAMADAS" | tr -d ' ')" -eq "$llamas_antes" ] || fail "(7) sesión sin registro: ni mensajes"
echo "ok (7): una sesión fuera de todo registro abierto no recibe ni una tecla ni una anotación"

# (8) Patrón de tabla ancho (.*, sin ancla): la tabla se rechaza al cargar y no se
# contesta nada de nada.
abrir c8 "$(seses r8 glm)" "$(pres '.*' Aprobado)"
encender c8
pan r8 "$P/eco-glm.txt"; espera r8 'Allow once'
antes=$(cat "$CORRIDA_STATE"/*/decisiones.jsonl 2>/dev/null | wc -l | tr -d ' ')
corre r8; [ $? -eq 2 ] || fail "(8) patrón ancho => error de carga (rc 2)"
[ "$(nteclas r8)" -eq 0 ] || fail "(8) patrón ancho: ninguna tecla"
[ "$(wc -l <"$LLAMADAS" | tr -d ' ')" -eq "$llamas_antes" ] || fail "(8) patrón ancho: ningún mensaje"
despues=$(cat "$CORRIDA_STATE"/*/decisiones.jsonl 2>/dev/null | wc -l | tr -d ' ')
[ "$despues" -eq "$antes" ] || fail "(8) patrón ancho: ni anota ($antes -> $despues)"
echo "ok (8): un patrón ancho en la tabla del registro se rechaza al cargar y no se contesta nada"

# (9) TOCTOU: la pantalla que cambia entre la lectura y el envío no recibe nada.
# El stub de tmux devuelve una pantalla distinta en la SEGUNDA captura.
abrir c9 "$(seses r9 claude)" "$(pres 'echo hola' Aprobado)"
encender c9
STUB_TM="$T/bin/tmux-toctou"
cat >"$STUB_TM" <<STUB
#!/bin/sh
printf '%s\n' "TMUX \$*" >> "$TMUX_LOG"
case "\$1" in
  capture-pane)
    n=\$(( \$(cat "$T/toctou-n" 2>/dev/null || echo 0) + 1 )); echo \$n >"$T/toctou-n"
    if [ "\$n" -gt 1 ]; then cat "$P/eco-glm-otro.txt"; else cat "$P/eco-glm.txt"; fi
    exit 0;;
  display-message) printf '%s\n' "$WORK"; exit 0;;
  send-keys) exit 0;;
esac
exit 0
STUB
chmod +x "$STUB_TM"
antes=$(cat "$CORRIDA_STATE"/*/decisiones.jsonl 2>/dev/null | wc -l | tr -d ' ')
TMUX_BIN="$STUB_TM" bash "$CORR" responder r9 >/dev/null 2>&1; [ $? -eq 1 ] || fail "(9) pantalla cambiada => no actuó (rc 1)"
! grep -q '^TMUX send-keys -t r9 ' "$TMUX_LOG" || fail "(9) con la pantalla cambiada no se manda nada"
despues=$(cat "$CORRIDA_STATE"/*/decisiones.jsonl 2>/dev/null | wc -l | tr -d ' ')
[ "$despues" -eq "$((antes + 1))" ] || fail "(9) la pantalla cambiada se anota ($antes -> $despues)"
D="$(udec c9)"
[ "$(jcampo clase "$D")" = "pantalla" ] || fail "(9) clase pantalla: $D"
[ "$(jcampo enviado "$D")" = "false" ] || fail "(9) nada enviado: $D"
echo "ok (9): la pantalla que cambia entre lectura y envío no recibe ninguna tecla (y se anota)"

# (10) Tres diálogos en 10 min con cambio de modo conocido => cambia de modo en
# vez de seguir contestando; con los diálogos viejos (>10 min) contesta normal.
abrir c10 "$(seses r10a glm r10b glm)" "$(pres 'echo hola' Aprobado)"
encender c10
now=$(date +%s)
{ printf '{"ts":%d,"sesion":"r10a","clase":"comando"}\n' "$((now - 30))"
  printf '{"ts":%d,"sesion":"r10a","clase":"comando"}\n' "$((now - 20))"; } >"$CORRIDA_STATE/c10/decisiones.jsonl"
pan r10a "$P/eco-glm.txt"; espera r10a 'Allow once'
corre r10a; [ $? -eq 0 ] || fail "(10) el tercer diálogo se resuelve cambiando de modo (rc 0)"
tecla_fue r10a '-l /mode yolo' || fail "(10) debía mandar el cambio de modo: $(grep 'send-keys -t r10a' "$TMUX_LOG")"
tecla_fue r10a Enter || fail "(10) el cambio de modo entra con Enter: $(grep 'send-keys -t r10a' "$TMUX_LOG")"
! grep -q '^TMUX send-keys -t r10a y$' "$TMUX_LOG" || fail "(10) tercer diálogo: NO se contesta con la tecla de siempre"
D="$(udec c10)"
[ "$(jcampo clase "$D")" = "modo" ] || fail "(10) clase modo: $D"
{ printf '{"ts":%d,"sesion":"r10b","clase":"comando"}\n' "$((now - 800))"
  printf '{"ts":%d,"sesion":"r10b","clase":"comando"}\n' "$((now - 700))"; } >"$CORRIDA_STATE/c10/decisiones.jsonl"
pan r10b "$P/eco-glm.txt"; espera r10b 'Allow once'
corre r10b; [ $? -eq 0 ] || fail "(10b) diálogos de hace más de 10 min: se contesta normal"
tecla_fue r10b y || fail "(10b) fuera de la ventana de 10 min contesta con la tecla de la tabla: $(grep 'send-keys -t r10b' "$TMUX_LOG")"
! grep -q '^TMUX send-keys -t r10b -l' "$TMUX_LOG" || fail "(10b) sin ráfaga no hay cambio de modo"
echo "ok (10): tres diálogos en 10 min => cambio de modo (/mode yolo + Enter); viejos => tecla normal"

# (11) Tecla sin medir (unknown en la tabla): esa vía no se usa, escala.
abrir c11 "$(seses r11 deepseek)" "$(pres 'echo hola' Aprobado)"
encender c11
pan r11 "$P/eco-glm.txt"; espera r11 'Allow once'
: >"$LLAMADAS"
corre r11; [ $? -eq 1 ] || fail "(11) sin tecla medida no se contesta"
[ "$(nteclas r11)" -eq 0 ] || fail "(11) sin tecla medida no hay tecla"
grep -qF 'NECESITO TU RESPUESTA' "$LLAMADAS" || fail "(11) sin tecla medida => escala: $(cat "$LLAMADAS")"
echo "ok (11): un CLI sin teclas medidas en la tabla escala en vez de inventar teclas"

echo "TODO VERDE: corrida-responder"
