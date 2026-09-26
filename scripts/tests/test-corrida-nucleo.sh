#!/bin/bash
# 9.2 abrir/lanzar-sesion/cerrar + corrida_mensaje, con tmux propio (-L) y CLIs de
# mentira. Ninguna prueba manda un Telegram real ni despierta a un agente vivo:
# OPENCLAW_BIN apunta a un stub que solo anota. Uso: bash scripts/tests/test-corrida-nucleo.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
texto_json() { # $1 linea de mensajes.jsonl -> su campo 'texto' decodificado (sin \uXXXX)
  printf '%s' "$1" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('texto',''))"
}

CORR=scripts/mac/corrida.sh
CORR_ABS="$PWD/scripts/mac/corrida.sh"
RB="$PWD/scripts/tests/fixtures/corrida/runbook-simulacro.md"
[ -x "$CORR" ] || fail "falta $CORR"
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba de sesiones"

T=$(mktemp -d) || exit 1
L="nucleo$$"
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ses" "$T/tui"

# CLIs de mentira: pintan su barra y consumen el encargo por stdin, dejando recibo en
# pantalla (como un TUI: la caja se vacia al entrar la linea) y en RECIBIDAS.
cat >"$T/bin/cli-bueno" <<'CLI'
#!/bin/sh
echo "BARRITA-YOLO"
while IFS= read -r line; do
  printf 'RECIBIDO: %s\n' "$line"
  printf '%s\n' "$line" >> "$RECIBIDAS"
done
CLI
cat >"$T/bin/cli-mala-barra" <<'CLI'
#!/bin/sh
echo "OTRA-COSA"
cat >> "$RECIBIDAS"
CLI
# cli-tarde tarda su barra: abre la ventana donde la carrera lanzar/cerrar vive.
cat >"$T/bin/cli-tarde" <<'CLI'
#!/bin/sh
sleep 2.5
echo "BAR-TARDE-9"
while IFS= read -r line; do
  printf 'RECIBIDO: %s\n' "$line"
  printf '%s\n' "$line" >> "$RECIBIDAS"
done
CLI
# cli-ruin muere al instante: deja que la inyeccion del flag (mutada) corra su curso.
cat >"$T/bin/cli-ruin" <<'CLI'
#!/bin/sh
printf 'RUIN: %s\n' "$*" >> "$RECIBIDAS"
exit 3
CLI
chmod +x "$T/bin"/cli-bueno "$T/bin"/cli-mala-barra "$T/bin"/cli-tarde "$T/bin"/cli-ruin
export RECIBIDAS="$T/recibidas.txt"

# Tabla de modos propia de la prueba (el registro manda, no el entorno).
printf 'bueno\tcli-bueno\t--modo-bueno-9\tBARRITA-YOLO\t--\t--\t--\n' >"$T/modos.tsv"
printf 'malo\tcli-mala-barra\t--modo-malo-9\tBARRITA-YOLO\t--\t--\t--\n' >>"$T/modos.tsv"
printf 'tarde\tcli-tarde\t--modo-tarde-9\tBAR-TARDE-9\t--\t--\t--\n' >>"$T/modos.tsv"
# IA: el binario de esta fila lleva comandos inyectados; jamas debe llegar a un sh.
printf 'inyecta\ttocar; touch %s/inyeccion-9x; true\t--modo-9\tBARRITA-YOLO\t--\t--\t--\n' "$T" >>"$T/modos.tsv"
# JA: el flag de esta fila lleva comandos inyectados; idem, jamas a un sh -c.
printf 'jaflag\tcli-ruin\t--modo; touch %s/ja-marker-9x; true\tBARRITA-YOLO\t--\t--\t--\n' "$T" >>"$T/modos.tsv"

# Stub openclaw: anota, no manda. El destino es unico para probar que no entra al repo.
# CRON_RM_FAIL=1 hace fallar cron rm; LISTA_MALA=1 con LISTA_DESPUES_DE=n
# falla todo cron list despues del n-esimo. CRON_RM_SUENIO/MSJ_SUENIO/LISTA_SUENIO=n
# duermen esa llamada n segundos (para ejercitar el tope de reloj).
LLAMADAS="$T/llamadas.log"
DESTINO="DESTINO-UNICO-9X"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
printf '%s\n' "OPENCLAW \$*" >> "$LLAMADAS"
case "\$*" in
  *cron\ rm*)
    [ "\${CRON_RM_SUENIO:-0}" != "0" ] && sleep "\${CRON_RM_SUENIO}"
    [ "\${CRON_RM_FAIL:-0}" = "1" ] && exit 1
    if ! grep -q " \$3\$" "$T/cron-puesto" 2>/dev/null; then exit 1; fi
    grep -v " \$3\$" "$T/cron-puesto" > "$T/cron-puesto.n" 2>/dev/null; mv "$T/cron-puesto.n" "$T/cron-puesto"
    printf '{}';;
  *cron\ list*)
    [ "\${LISTA_SUENIO:-0}" != "0" ] && sleep "\${LISTA_SUENIO}"
    n=\$([ -f "$T/lists" ] && wc -l < "$T/lists" || echo 0); n=\$((n + 1)); echo x >> "$T/lists"
    if [ "\${LISTA_MALA:-0}" != "0" ] && [ "\$n" -gt "\${LISTA_DESPUES_DE:-0}" ]; then exit 1; fi
    printf '{"jobs":[{"name":"cuotas-proveedores","delivery":{"to":"$DESTINO"}}'
    if [ "\${DEST_AMBIGUO:-0}" = "1" ]; then
      printf ',{"name":"cuotas-proveedores","delivery":{"to":"OTRO-DESTINO-9Z"}}'
    fi
    if [ -f "$T/cron-puesto" ]; then
      while IFS= read -r linea; do
        [ -n "\$linea" ] && printf ',{"name":"%s","id":"%s"}' "\${linea%% *}" "\${linea#* }"
      done < "$T/cron-puesto"
    fi
    printf ']}';;
  *cron\ add*)
    # abrir ya no crea crons: si algo llama a cron add, queda anotado y la
    # prueba que vigila la ausencia lo pone en rojo.
    printf '{}';;
  *message\ send*) [ "\${MSJ_SUENIO:-0}" != "0" ] && sleep "\${MSJ_SUENIO}"; [ "\${ENVIO_MODO:-ok}" = "mal" ] && exit 1; printf '%s' "\${MSJ_PREAMBULO:-}"; printf '{"ok":true,"messageId":%s}' "\${MSJ_ID:-\"m1\"}";;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw"

# Shim tmux: servidor propio + bitacora de llamadas; con SWALLOW=1 traga los primeros
# SWALLOW_N Enter de la sesion SWALLOW_SES (por defecto, uno); con SETENV_FAIL=ses
# falla el marcado de esa sesion.
TMUX_LOG="$T/tmux.log"
cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
printf '%s\n' "TMUX \$*" >> "$TMUX_LOG"
if [ -n "\${SETENV_FAIL:-}" ] && [ "\$*" = "set-environment -t =\${SETENV_FAIL} OPENCLAW_WATCH 1" ]; then
  exit 1
fi
if [ "\${SWALLOW:-0}" != "0" ]; then
  case "\$*" in
    "send-keys -t =\${SWALLOW_SES:-}: Enter")
      n=\$(cat "$T/tragado" 2>/dev/null || echo 0)
      [ "\$n" -lt "\${SWALLOW_N:-1}" ] && { echo \$((n + 1)) > "$T/tragado"; exit 0; }
      ;;
  esac
fi
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux-shim"

export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas"
export OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux-shim"

# (0) abrir en simulacro: registro 600, dir 700, cron hombre-muerto, destino guardado.
bash "$CORR" abrir t1 --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" --simulacro >/dev/null \
  || fail "abrir fallo"
permiso() { # $1 ruta: stat portable (macOS usa -f, Linux -c; en Linux stat -f no falla, asi que se elige por sistema)
  if [ "$(uname)" = "Darwin" ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}
[ -f "$T/corridas/t1/registro.json" ] || fail "sin registro"
[ "$(permiso "$T/corridas/t1")" = "700" ] || fail "el dir no queda 700"
[ "$(permiso "$T/corridas/t1/registro.json")" = "600" ] || fail "el registro no queda 600"
grep -q "cron add" "$LLAMADAS" && fail "abrir creo un cron: el reloj es el unico avance-tareas global"
grep -q '"schema": *"corrida.v2"' "$T/corridas/t1/registro.json" || fail "abrir no escribe v2"
grep -q '"seguimiento_global": *true' "$T/corridas/t1/registro.json" || fail "abrir no declara el reloj global"
grep -q '"simulacro": *true' "$T/corridas/t1/registro.json" || fail "el registro no dice simulacro"

# (0d) 9.2: abrir manda un aviso ABIERTA con el nombre de la corrida, y en
# practica no pide respuesta ni deja el destino escrito.
ultima_abierta="$(grep '"etiqueta": *"ABIERTA"' "$T/corridas/t1/mensajes.jsonl" | tail -1)"
[ -n "$ultima_abierta" ] || fail "abrir no dejo el aviso ABIERTA en mensajes.jsonl"
printf '%s' "$ultima_abierta" | grep -q '"ok": *true' \
  || fail "el aviso ABIERTA no salio ok: $ultima_abierta"
texto_json "$ultima_abierta" | grep -q "Runbook minimo del simulacro" \
  || fail "el aviso ABIERTA no trae el nombre de la corrida: $ultima_abierta"
texto_json "$ultima_abierta" | grep -q '🧪 PRÁCTICA — no contestes' \
  || fail "el aviso ABIERTA en practica no trae el prefijo de practica: $ultima_abierta"
printf '%s' "$ultima_abierta" | grep -q "$DESTINO" \
  && fail "el aviso ABIERTA dejo el destino escrito: $ultima_abierta"
: > "$LLAMADAS"

# (0b) id invalido: nada de salir del directorio de estado ni inyectar comandos.
bash "$CORR" abrir '../fuga' --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 \
  && fail "abrir acepto un id con ../"
[ ! -e "$T/fuga" ] || fail "abrir escapo del directorio de estado con ../"
bash "$CORR" abrir 'a;b' --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 \
  && fail "abrir acepto un id con ;"

# (0c) FC: un flag con valor faltante muere rapido con error claro, no se queda
# masticando la misma opcion para siempre (rc 99 = sigue vivo a los 2 s).
colgado() { # $@ comando: rc 99 si sigue vivo a los 2 s; si no, el rc del comando
  "$@" >/dev/null 2>&1 &
  local p=$!
  sleep 2
  if kill -0 "$p" 2>/dev/null; then
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
    return 99
  fi
  wait "$p" 2>/dev/null
}
colgado bash "$CORR" abrir t1 --runbook; rc=$?
[ "$rc" -eq 99 ] && fail "abrir con --runbook sin valor quedo colgado"
[ "$rc" -ne 0 ] || fail "abrir debio rechazar --runbook sin valor"
out="$(bash "$CORR" abrir t1 --runbook 2>&1)"
printf '%s' "$out" | grep -q "sin valor" || fail "el flag sin valor no se explica"
colgado bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre; rc=$?
[ "$rc" -eq 99 ] && fail "lanzar-sesion con --nombre sin valor quedo colgado"
[ "$rc" -ne 0 ] || fail "lanzar-sesion debio rechazar --nombre sin valor"

# (1) lanzar bueno con encargo: vive, barra ok, entrega, registro la anota.
printf 'haz lo pedido y termina con LISTO\n' >"$T/encargo.txt"
: > "$TMUX_LOG"
S=$(bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-buena --encargo "$T/encargo.txt") \
  || fail "lanzar bueno fallo"
[ "$S" = "ses-buena" ] || fail "la sesion se llama $S"
grep -q "haz lo pedido" "$RECIBIDAS" || fail "el encargo no llego al CLI"
grep -q '"nombre": *"ses-buena"' "$T/corridas/t1/registro.json" || fail "el registro no anota la sesion"
n1=$(grep -c "send-keys -t =ses-buena: Enter" "$TMUX_LOG")
[ "$n1" -eq 1 ] || fail "sin Enter tragado se mandaron $n1 Enter (debe ser uno)"

# (1b) abrir sobre una corrida existente se niega y no pisa nada.
bash "$CORR" abrir t1 --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" --simulacro >/dev/null 2>&1 \
  && fail "abrir piso una corrida existente"
grep -q '"nombre": *"ses-buena"' "$T/corridas/t1/registro.json" || fail "el abrir repetido borro sesiones"
grep -q "cron add" "$LLAMADAS" && fail "abrir repetido creo un cron"

# (1d) IB: carrera abrir x abrir del mismo id — los dos pasan el chequeo
# temprano; el perdedor falla bajo lock sin escribir nada. Sin crons de por
# medio: queda un solo registro.
bash "$CORR" abrir t-carrera --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 &
a1=$!
bash "$CORR" abrir t-carrera --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 &
a2=$!
wait "$a1"; r1=$?
wait "$a2"; r2=$?
{ [ "$r1" -ne 0 ] || [ "$r2" -ne 0 ]; } || fail "la carrera de abrir debio dejar un perdedor"
{ [ "$r1" -eq 0 ] || [ "$r2" -eq 0 ]; } || fail "la carrera de abrir debio dejar un ganador"
[ -f "$T/corridas/t-carrera/registro.json" ] || fail "la carrera no dejo registro"
grep -q "cron add" "$LLAMADAS" && fail "la carrera creo un cron"

# (1e) JC: lista de crons colgada — abrir muere al tope sin escribir nada.
# (El destino sale de la lista; sin lista legible no hay apertura.)
out="$(LISTA_SUENIO=12 CORR_TOPE_RED=3 bash "$CORR" abrir t-jc --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con la lista colgada debio fallar cerrado"
printf '%s' "$out" | grep -q "destino\|lista" || fail "la lista colgada no se reporta"
[ -f "$T/corridas/t-jc/registro.json" ] && fail "con la lista colgada se escribio registro"
[ -d "$T/corridas/t-jc/.lock" ] && fail "con la lista colgada quedo lock puesto"

# (1c) tmux -t sin = matchea por prefijo: ses-prefija-2 viva no estorba a ses-prefija.
"$TM_REAL" -L "$L" new-session -d -s ses-prefija-2 >/dev/null 2>&1 || fail "no se creo ses-prefija-2"
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-prefija --encargo "$T/encargo.txt" >/dev/null \
  || fail "una sesion con prefijo comun robo el nombre"
"$TM_REAL" -L "$L" kill-session -t "=ses-prefija" 2>/dev/null
"$TM_REAL" -L "$L" kill-session -t "=ses-prefija-2" 2>/dev/null

# (2) la marca ocurre ANTES del primer send-keys (orden leido del log del shim).
marca=$(grep -n "set-environment -t =ses-buena OPENCLAW_WATCH 1" "$TMUX_LOG" | head -1 | cut -d: -f1)
tecla=$(grep -n "send-keys -t =ses-buena" "$TMUX_LOG" | head -1 | cut -d: -f1)
[ -n "$marca" ] && [ -n "$tecla" ] && [ "$marca" -lt "$tecla" ] \
  || fail "la marca no va antes del primer send-keys (marca=$marca tecla=$tecla)"

# (3) barra ausente: falla, no entrega nada a esa sesion y no deja sesion huérfana.
: > "$TMUX_LOG"
bash "$CORR" lanzar-sesion t1 carril malo "$T/ses" --nombre ses-mala >/dev/null 2>&1 \
  && fail "con barra ausente debio fallar"
grep -q "send-keys -t =ses-mala" "$TMUX_LOG" && fail "con barra ausente no se manda nada"
"$TM_REAL" -L "$L" has-session -t "=ses-mala" 2>/dev/null && fail "la sesion fallida quedo viva"

# (4) Enter tragado: reintenta y el encargo igual llega; dos Enter, no mas.
export SWALLOW=1 SWALLOW_SES=ses-traga
: > "$TMUX_LOG"; : > "$RECIBIDAS"; rm -f "$T/tragado"
S=$(bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-traga --encargo "$T/encargo.txt") \
  || fail "con Enter tragado debio reintentar y entregar"
n=$(grep -c "send-keys -t =ses-traga: Enter" "$TMUX_LOG")
[ "$n" -eq 2 ] || fail "Enter sin reintentar bien (n=$n)"
grep -q "haz lo pedido" "$RECIBIDAS" || fail "tras el reintento el encargo no llego"
unset SWALLOW SWALLOW_SES

# (4b) caja que nunca se vacia: falla, mata la sesion y no la registra.
export SWALLOW=1 SWALLOW_N=2 SWALLOW_SES=ses-cong
rm -f "$T/tragado"
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-cong --encargo "$T/encargo.txt" >/dev/null 2>&1 \
  && fail "con la caja sin vaciarse, lanzar-sesion registro la sesion igual"
"$TM_REAL" -L "$L" has-session -t "=ses-cong" 2>/dev/null && fail "la sesion congelada quedo viva"
grep -q '"nombre": *"ses-cong"' "$T/corridas/t1/registro.json" && fail "la sesion congelada quedo registrada"
unset SWALLOW SWALLOW_N SWALLOW_SES

# (5) jerga: corrida_mensaje la rechaza y no la manda.
. scripts/mac/corrida/lib.sh
corrida_mensaje t1 AVANZA "1 de 2 partes terminadas" "se integro el PR de mensajes" "sigue la politica" "nada" 2>/dev/null \
  && fail "el mensaje con jerga debio rechazarse"
grep -q "se integro el PR" "$LLAMADAS" && fail "la jerga nunca sale del stub"

# (6) simulacro: AVANZA acumula sin mandar; lo inmediato sale con el prefijo de
# practica, el nombre de la corrida y el texto enviado ES el del contrato.
: >"$LLAMADAS"
corrida_mensaje t1 AVANZA "1 de 2 partes terminadas" "quedo lista la primera parte" "sigue la parte de mensajes" "nada" \
  || fail "AVANZA en simulacro debio acumular"
grep -q 'message send' "$LLAMADAS" && fail "AVANZA en simulacro mando en vez de acumular"
grep -q '"cambio": *"quedo lista la primera parte"' "$T/corridas/t1/eventos-seguimiento.jsonl" \
  || fail "AVANZA en simulacro no dejo el evento"
: >"$LLAMADAS"
corrida_mensaje t1 DETENIDA "1 de 2 partes terminadas" "quedo lista la primera parte" "sigue la parte de mensajes" "nada" \
  || fail "DETENIDA en simulacro fallo"
enc_t1="$(corrida_encabezado t1)"
printf '🧪 PRÁCTICA — no contestes 🔴 [DETENIDA] %s, 1 de 2 partes terminadas\n\nQué cambió: quedo lista la primera parte\n\nQué sigue: sigue la parte de mensajes\n\nQué necesito de ti: nada\n' "$enc_t1" >"$T/esp-sim.txt"
d=$(grep -n "OPENCLAW message send" "$LLAMADAS" | tail -1 | cut -d: -f1)
tail -n +"$d" "$LLAMADAS" | sed '1s/.* -m //' >"$T/obtenido.txt"
cmp -s "$T/esp-sim.txt" "$T/obtenido.txt" || fail "el texto enviado no es el de seguimiento.v1"
printf '%s' "$enc_t1" | grep -q "Runbook minimo del simulacro" \
  || fail "corrida_encabezado no trae el titulo del runbook: $enc_t1"

# (6b) el prefijo de practica de la primera linea no invalida; y no se reescribe el archivo.
printf '🧪 PRÁCTICA — no contestes [AVANZA] Fase 9, 1 de 2 partes terminadas\nQué cambió: quedo lista la primera parte\nQué sigue: sigue la parte de mensajes\nQué necesito de ti: nada\n' >"$T/prefijo.txt"
cp "$T/prefijo.txt" "$T/prefijo.orig"
mensaje_valido "$T/prefijo.txt" || fail "el prefijo de practica invalida un mensaje valido"
cmp -s "$T/prefijo.txt" "$T/prefijo.orig" || fail "mensaje_valido reescribe el archivo de quien llama"

# (6c) la ruta del cron es fisica y absoluta; una corrida NO simulacro no lleva prefijo.
mkdir -p "$T/c-real"
ln -s "$T/c-real" "$T/c-sym"
( cd "$T" && CORRIDA_STATE=c-sym bash "$CORR_ABS" abrir t-sym --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null ) \
  || fail "abrir con CORRIDA_STATE relativo fallo"
RB_REL="scripts/tests/fixtures/corrida/runbook-simulacro.md"
bash "$CORR" abrir t-rel2 --runbook "$RB_REL" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir con runbook relativo fallo"
grep -qF "\"runbook\": \"$RB_REL" "$T/corridas/t-rel2/registro.json" \
  && fail "el runbook relativo se guardo sin resolver a absoluta"
grep -qF "\"runbook\": \"$PWD/$RB_REL\"" "$T/corridas/t-rel2/registro.json" \
  || fail "el runbook guardado no es la absoluta resuelta"
bash "$CORR" abrir t-ns --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir sin simulacro fallo"
grep -q '"simulacro": *false' "$T/corridas/t-ns/registro.json" \
  || fail "el registro de t-ns no dice no-simulacro"
ultima_abierta_ns="$(grep '"etiqueta": *"ABIERTA"' "$T/corridas/t-ns/mensajes.jsonl" | tail -1)"
[ -n "$ultima_abierta_ns" ] || fail "abrir sin simulacro no dejo el aviso ABIERTA"
texto_json "$ultima_abierta_ns" | grep -q '▶️ \[ABIERTA\]' \
  || fail "el aviso ABIERTA de una corrida real no trae su prefijo: $ultima_abierta_ns"
texto_json "$ultima_abierta_ns" | grep -q 'PRÁCTICA' \
  && fail "el aviso ABIERTA de una corrida real trae el prefijo de practica: $ultima_abierta_ns"

# (6d) corrida_mensaje guarda la prueba del mensaje: messageId extraido de un
# stdout con preambulo, at numerico, texto con el prefijo de practica; el
# destino nunca queda escrito. Envio fallido -> message_id null, ok false.
: > "$T/corridas/t1/mensajes.jsonl"
export MSJ_PREAMBULO="ruido de arranque del CLI
mas ruido
" MSJ_ID=4242
corrida_mensaje t1 DETENIDA "1 de 2 partes terminadas" "hubo un percance" "se retoma" "nada" \
  || fail "DETENIDA con preambulo en el stdout fallo"
unset MSJ_PREAMBULO MSJ_ID
ultima=$(tail -n1 "$T/corridas/t1/mensajes.jsonl")
printf '%s' "$ultima" | grep -q '"message_id": 4242' \
  || fail "corrida_mensaje no extrajo el messageId del preambulo: $ultima"
printf '%s' "$ultima" | grep -qE '"at": [0-9]+' \
  || fail "corrida_mensaje no guardo un at numerico: $ultima"
texto_json "$ultima" | grep -q '🧪 PRÁCTICA — no contestes 🔴 \[DETENIDA\]' \
  || fail "corrida_mensaje no guardo el texto con el prefijo de practica: $ultima"
printf '%s' "$ultima" | grep -q "$DESTINO" \
  && fail "corrida_mensaje dejo el destino escrito en mensajes.jsonl: $ultima"

export ENVIO_MODO=mal
corrida_mensaje t1 DETENIDA "1 de 2 partes terminadas" "hubo un percance" "se retoma" "nada" \
  2>/dev/null && fail "el envio fallido debio devolver distinto de 0"
unset ENVIO_MODO
ultima=$(tail -n1 "$T/corridas/t1/mensajes.jsonl")
printf '%s' "$ultima" | grep -q '"ok": false' \
  || fail "el envio fallido no quedo con ok:false: $ultima"
printf '%s' "$ultima" | grep -q '"message_id": null' \
  || fail "el envio fallido no quedo con message_id:null: $ultima"

# (6e) BLOQUEANTE del revisor: un runbook cuyo titulo trae jerga (aqui "CI")
# no tumba los mensajes de esa corrida ni la deja atorada sin poder cerrar.
# corrida_encabezado cae al id, y abrir/cerrar SIGUEN mandando su aviso.
RB_JERGA="$PWD/scripts/tests/fixtures/corrida/runbook-titulo-jerga.md"
bash "$CORR" abrir t-jerga --runbook "$RB_JERGA" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir con un runbook de titulo con jerga fallo"
enc_jerga="$(corrida_encabezado t-jerga)"
printf '%s' "$enc_jerga" | grep -q '^t-jerga (abrió' \
  || fail "corrida_encabezado no cayo al id con un titulo con jerga: $enc_jerga"
abierta_jerga="$(grep '"etiqueta": *"ABIERTA"' "$T/corridas/t-jerga/mensajes.jsonl" | tail -1)"
[ -n "$abierta_jerga" ] || fail "abrir con titulo con jerga no dejo el aviso ABIERTA"
printf '%s' "$abierta_jerga" | grep -q '"ok": *true' \
  || fail "el aviso ABIERTA con titulo con jerga no salio ok: $abierta_jerga"
bash "$CORR" cerrar t-jerga >/dev/null 2>&1 \
  || fail "cerrar con un runbook de titulo con jerga fallo (la corrida quedaria atorada)"
grep -q '"estado": *"cerrada"' "$T/corridas/t-jerga/registro.json" \
  || fail "t-jerga no quedo cerrada"
cerrada_jerga="$(grep '"etiqueta": *"CERRADA"' "$T/corridas/t-jerga/mensajes.jsonl" | tail -1)"
[ -n "$cerrada_jerga" ] || fail "cerrar con titulo con jerga no dejo el aviso CERRADA"
printf '%s' "$cerrada_jerga" | grep -q '"ok": *true' \
  || fail "el aviso CERRADA con titulo con jerga no salio ok: $cerrada_jerga"
# 9.2: en una corrida real TODOS los mensajes llevan el prefijo ▶️, no solo ABIERTA.
texto_json "$cerrada_jerga" | grep -q '^▶️ ✅ \[CERRADA\]' \
  || fail "el aviso CERRADA de una corrida real no trae su prefijo: $cerrada_jerga"

# (6f) BLOQUEANTE del revisor (CodeRabbit, lib.sh:613): un titulo que repite
# un marcador reservado del mensaje ("Comando: ") pasa jerga_en_texto pero
# rompe la forma de la linea 1 igual que la jerga — tambien cae al id.
RB_MARCADOR="$PWD/scripts/tests/fixtures/corrida/runbook-titulo-marcador.md"
bash "$CORR" abrir t-marcador --runbook "$RB_MARCADOR" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir con un runbook de titulo con un marcador reservado fallo"
enc_marcador="$(corrida_encabezado t-marcador)"
printf '%s' "$enc_marcador" | grep -q '^t-marcador (abrió' \
  || fail "corrida_encabezado no cayo al id con un titulo con un marcador reservado: $enc_marcador"
abierta_marcador="$(grep '"etiqueta": *"ABIERTA"' "$T/corridas/t-marcador/mensajes.jsonl" | tail -1)"
printf '%s' "$abierta_marcador" | grep -q '"ok": *true' \
  || fail "el aviso ABIERTA con titulo-marcador no salio ok: $abierta_marcador"
bash "$CORR" cerrar t-marcador >/dev/null 2>&1 \
  || fail "cerrar con un runbook de titulo-marcador fallo (la corrida quedaria atorada)"
cerrada_marcador="$(grep '"etiqueta": *"CERRADA"' "$T/corridas/t-marcador/mensajes.jsonl" | tail -1)"
printf '%s' "$cerrada_marcador" | grep -q '"ok": *true' \
  || fail "el aviso CERRADA con titulo-marcador no salio ok: $cerrada_marcador"

# (9) con el entorno vacio se usa la misma tabla del registro.
: > "$TMUX_LOG"
env -i PATH="$T/bin:/opt/homebrew/bin:/usr/bin:/bin" HOME="$HOME" CORRIDA_STATE="$T/corridas" \
  OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux-shim" RECIBIDAS="$T/recibidas.txt" \
  bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-vacia >/dev/null \
  || fail "con env -i fallo"
grep -q -- "--modo-bueno-9" "$TMUX_LOG" || fail "con env -i no se uso la tabla del registro"

# (9b) dos lanzamientos en paralelo: el registro no pierde ninguna sesion.
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-par-a --encargo "$T/encargo.txt" >/dev/null 2>&1 &
p1=$!
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-par-b --encargo "$T/encargo.txt" >/dev/null 2>&1 &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
[ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] || fail "un lanzamiento paralelo fallo (r1=$r1 r2=$r2)"
grep -q '"nombre": *"ses-par-a"' "$T/corridas/t1/registro.json" || fail "el registro perdio a ses-par-a"
grep -q '"nombre": *"ses-par-b"' "$T/corridas/t1/registro.json" || fail "el registro perdio a ses-par-b"

# (9c) nombre de sesion invalido: se rechaza antes de crear nada. Y el rol tambien
# es cerrado: lead o carril.
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre "con espacio" --encargo "$T/encargo.txt" >/dev/null 2>&1 \
  && fail "un nombre con espacio debio rechazarse"
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre "mai:l" >/dev/null 2>&1 \
  && fail "un nombre con : debio rechazarse"
"$TM_REAL" -L "$L" list-sessions -F '#{session_name}' 2>/dev/null | grep -q "mai:l" && fail "la sesion de nombre invalido se creo"
bash "$CORR" lanzar-sesion t1 jefe bueno "$T/ses" --nombre ses-jefe >/dev/null 2>&1 \
  && fail "un rol fuera del conjunto debio rechazarse"
grep -q '"nombre": *"ses-jefe"' "$T/corridas/t1/registro.json" && fail "la sesion de rol invalido quedo registrada"

# (9i) GD-1: un PATH con espacio no rompe el arranque — el PATH embebido en el
# comando de tmux va citado adentro (sh -c lo parsea y el espacio parte el assignment).
mkdir -p "$T/co n"
PATH="$T/co n:$PATH" bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-path >/dev/null 2>&1 \
  || fail "un PATH con espacio rompio el arranque de la sesion"
grep -q '"nombre": *"ses-path"' "$T/corridas/t1/registro.json" || fail "ses-path no quedo registrada"

# (9j) IA: un binario de la tabla con comandos inyectados jamas llega a un sh: se
# rechaza cerrado, con diagnostico claro, y sin ejecutar nada.
out="$(bash "$CORR" lanzar-sesion t1 carril inyecta "$T/ses" --nombre ses-iny 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "el binario inyectado debio rechazarse"
printf '%s' "$out" | grep -q "binario invalido" || fail "el rechazo no diagnostica el binario invalido"
[ -e "$T/inyeccion-9x" ] && fail "la inyeccion del binario ejecuto codigo"

# (9k) JA: el flag de la tabla con comandos inyectados jamas llega al sh -c de tmux.
out="$(bash "$CORR" lanzar-sesion t1 carril jaflag "$T/ses" --nombre ses-jaf 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "el flag inyectado debio rechazarse"
printf '%s' "$out" | grep -q "flag invalido" || fail "el rechazo no diagnostica el flag invalido"
[ -e "$T/ja-marker-9x" ] && fail "la inyeccion del flag ejecuto codigo"
grep -q '"nombre": *"ses-jaf"' "$T/corridas/t1/registro.json" && fail "la sesion del flag inyectado quedo registrada"

# (9d) el marcado que falla no deja sesion viva ni sin marca.
SETENV_FAIL=ses-marka bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-marka >/dev/null 2>&1 \
  && fail "con el marcado fallando debio fallar el lanzamiento"
"$TM_REAL" -L "$L" has-session -t "=ses-marka" 2>/dev/null && fail "la sesion sin marca quedo viva"
grep -q '"nombre": *"ses-marka"' "$T/corridas/t1/registro.json" && fail "la sesion sin marca quedo registrada"
unset SETENV_FAIL

# (9e) Sin cron por corrida ya no hay "cron add sin id": abrir no llama a cron
# add nunca. La limpieza de ids legados (duplicados homonimos, lista ilegible)
# vive en test-corrida-seguimiento-global.sh, del lado de migrar-seguimiento.

# homonimos del canal con destinos DISTINTOS: abrir no elige, falla cerrado.
out="$(DEST_AMBIGUO=1 bash "$CORR" abrir t-amb --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con destinos ambiguos debio fallar cerrado"
printf '%s' "$out" | grep -q "ambigu" || fail "el fallo por destinos ambiguos no lo dice"

# (9f) lock del registro: fresco espera y falla; viejo se rompe (con aviso) y se toma.
mkdir "$T/corridas/t1/.lock"
lock_tomar "$T/corridas/t1/registro.json" >/dev/null 2>&1 \
  && fail "con lock fresco debio esperar y fallar"
rmdir "$T/corridas/t1/.lock"
mkdir "$T/corridas/t1/.lock"
touch -t 202001010000 "$T/corridas/t1/.lock"
lock_tomar "$T/corridas/t1/registro.json" >"$T/lock.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "con lock viejo debio recuperarse y tomar (rc=$rc)"
grep -q "lock viejo" "$T/lock.out" || fail "romper el lock viejo no avisa"
lock_soltar "$T/corridas/t1/registro.json"
[ -d "$T/corridas/t1/.lock" ] && fail "lock_soltar dejo el lock puesto"
# El guard de lock_tomar mutado a "if true" arma aqui su trap pisando el de
# limpieza del arranque, y lock_soltar lo borra: sin re-armarlo, un fail posterior
# (9g2) deja vivos el servidor tmux y el temporal.
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT

# (9f4) JB: un dueno vivo que refresca NO se rompe pasado el umbral — la edad que
# manda es la del TOKEN (el dir del lock ya va viejo: si se mirara el dir, roba).
CORR_LOCK_VIEJO=1; export CORR_LOCK_VIEJO
lock_tomar "$T/corridas/t1/registro.json" >/dev/null 2>&1 || fail "lock_tomar para el lease fallo"
sleep 1.2
lock_refrescar "$T/corridas/t1/registro.json"
bash -c ". '$PWD/scripts/mac/corrida/lib.sh'; lock_tomar '$T/corridas/t1/registro.json'" >/dev/null 2>&1 \
  && fail "un segundo lock_tomar robo un lock refrescado"
[ "$(cat "$T/corridas/t1/.lock/token" 2>/dev/null)" = "$CORR_LOCK_TOKEN" ] \
  || fail "el token del lock ya no es el nuestro (nos robaron)"
lock_soltar "$T/corridas/t1/registro.json"
[ -d "$T/corridas/t1/.lock" ] && fail "lock_soltar propio dejo el lock"
unset CORR_LOCK_VIEJO

# (9f5) JB: lock_soltar de un no-dueno no elimina el lock ajeno; el dueno si, via
# su EXIT (el holder trapea TERM -> exit -> el trap del lock corre).
cat >"$T/jb-holder.sh" <<JBH
. "$PWD/scripts/mac/corrida/lib.sh"
trap 'exit 143' TERM
lock_tomar "$T/corridas/t1/registro.json" || exit 9
sleep 30
JBH
bash "$T/jb-holder.sh" >/dev/null 2>&1 &
hjb=$!
k=0; while [ ! -f "$T/corridas/t1/.lock/token" ] && [ "$k" -lt 50 ]; do sleep 0.1; k=$((k+1)); done
[ -f "$T/corridas/t1/.lock/token" ] || fail "el holder nunca tomo el lock"
lock_soltar "$T/corridas/t1/registro.json"
[ -d "$T/corridas/t1/.lock" ] || fail "lock_soltar de un no-dueno elimino el lock ajeno"
kill -TERM "$hjb" 2>/dev/null; wait "$hjb" 2>/dev/null
k=0; while [ -d "$T/corridas/t1/.lock" ] && [ "$k" -lt 50 ]; do sleep 0.1; k=$((k+1)); done
[ -d "$T/corridas/t1/.lock" ] && fail "el EXIT del dueno no solto su lock"

# (9f6) 9.17: recuperacion explicita de un lock cuyo pid responde. La ruta
# automatica se rinde con kill -0 vivo (bien: no roba), pero dejaba al operador
# sin salida salvo borrar el directorio a mano. La explicita distingue los tres
# casos: dueno vivo que refresca (SE NIEGA, ni llamandola a proposito), dueno
# vivo colgado (recupera, audita y nombra el pid) y pid reciclado (recupera y
# dice que el token es de otro proceso).
command -v lock_recuperar_explicito >/dev/null 2>&1 \
  || fail "falta lock_recuperar_explicito en scripts/mac/corrida/lib.sh"
R9="$T/corridas/rec917"; mkdir -p "$R9"
CORR_LOCK_VIEJO=1; export CORR_LOCK_VIEJO

# (9f6a) dueno vivo que refresca: pasado el umbral, el refresco mantiene el token
# fresco y la explicita tambien se niega. Un lock vivo no se roba, ni a proposito.
lock_tomar "$R9/registro.json" >/dev/null 2>&1 || fail "(9f6a) el dueno no pudo tomar el lock"
sleep 1.2
lock_refrescar "$R9/registro.json"
out9a=$(lock_recuperar_explicito "$R9/.lock" 1 prueba 2>&1); rc9a=$?
[ "$rc9a" -ne 0 ] || fail "(9f6a) la recuperacion explicita robo el lock de un dueno vivo que refresca:
$out9a"
[ -f "$R9/.lock/token" ] || fail "(9f6a) el lock del dueno vivo desaparecio"
[ "$(cat "$R9/.lock/token" 2>/dev/null)" = "$CORR_LOCK_TOKEN" ] \
  || fail "(9f6a) el token del dueno vivo cambio"
printf '%s' "$out9a" | grep -qi 'refresca' \
  || fail "(9f6a) la negativa no explica que el dueno esta vivo y refresca:
$out9a"
lock_soltar "$R9/registro.json"
[ -d "$R9/.lock" ] && fail "(9f6a) lock_soltar propio dejo el lock"

# (9f6b) dueno vivo colgado: el proceso vive, nunca refresca, el token queda
# viejo. La ruta automatica se rinde (ese es el defecto 9.17); la explicita
# recupera, dice COLGADO y nombra el pid.
cat >"$T/r9-colgado.sh" <<COLG
. "$PWD/scripts/mac/corrida/lib.sh"
lock_tomar "$R9/registro.json" || exit 9
printf '%s' "\$CORR_LOCK_TOKEN" > "$T/r9-token-colgado"
sleep 30
COLG
bash "$T/r9-colgado.sh" >/dev/null 2>&1 &
colg_pid=$!
k=0; while [ ! -f "$T/r9-token-colgado" ] && [ "$k" -lt 50 ]; do sleep 0.1; k=$((k+1)); done
[ -f "$T/r9-token-colgado" ] || fail "(9f6b) el colgado nunca tomo el lock"
sleep 1.2
lock_abandonado_romper "$R9/.lock" 1 prueba-auto >/dev/null 2>&1 \
  && fail "(9f6b) la ruta automatica robo el lock de un proceso vivo"
[ -f "$R9/.lock/token" ] \
  || fail "(9f6b) la ruta automatica borro el lock de un proceso vivo"
out9b=$(lock_recuperar_explicito "$R9/.lock" 1 prueba 2>&1); rc9b=$?
[ "$rc9b" -eq 0 ] || fail "(9f6b) la explicita debio recuperar el lock del colgado (rc=$rc9b):
$out9b"
[ -d "$R9/.lock" ] && fail "(9f6b) la explicita dejo el lock colgado puesto:
$out9b"
printf '%s' "$out9b" | grep -qi 'colgado' \
  || fail "(9f6b) el aviso tiene que decir que era un colgado:
$out9b"
printf '%s' "$out9b" | grep -q "$colg_pid" \
  || fail "(9f6b) el aviso tiene que nombrar el pid del dueno colgado:
$out9b"
kill -TERM "$colg_pid" 2>/dev/null; wait "$colg_pid" 2>/dev/null

# (9f6c) pid reciclado: el token apunta a un proceso vivo pero nacido DESPUES del
# token: el dueno original murio y el pid ahora es de otro. La automatica tambien
# se rinde aqui; la explicita verifica la edad relativa, recupera y lo dice.
sleep 30 & rec_pid=$!
mkdir "$R9/.lock"
printf '%s-reciclado' "$rec_pid" >"$R9/.lock/token"
touch -t 202001010000 "$R9/.lock/token"
lock_abandonado_romper "$R9/.lock" 1 prueba-auto >/dev/null 2>&1 \
  && fail "(9f6c) la ruta automatica robo un lock con pid vivo"
[ -d "$R9/.lock" ] || fail "(9f6c) la ruta automatica borro el lock con pid vivo"
out9c=$(lock_recuperar_explicito "$R9/.lock" 1 prueba 2>&1); rc9c=$?
[ "$rc9c" -eq 0 ] || fail "(9f6c) la explicita debio recuperar el pid reciclado (rc=$rc9c):
$out9c"
[ -d "$R9/.lock" ] && fail "(9f6c) la explicita dejo el lock del reciclado puesto:
$out9c"
printf '%s' "$out9c" | grep -qi 'reciclado' \
  || fail "(9f6c) el aviso tiene que decir que el pid estaba reciclado:
$out9c"
kill "$rec_pid" 2>/dev/null; wait "$rec_pid" 2>/dev/null

# (9f6d) el etime trae ceros a la izquierda y bash lee 08/09 como octal
# invalido. Cada forma pone el 08 en un solo campo: hora, dia, minutos,
# segundos. Quitar el 10# de ese campo tiene que rendir la explicita.
mkdir -p "$T/bin08"
for et in '08:00:01' '08-00:00:01' '08:00' '00:08'; do
  cat >"$T/bin08/ps" <<PS08
#!/bin/sh
case "\$1 \$2" in
  "-o etime="*) printf '%s\n' "$et"; exit 0 ;;
esac
exec /bin/ps "\$@"
PS08
  chmod +x "$T/bin08/ps"
  sleep 30 & rec08=$!
  mkdir "$R9/.lock"
  printf '%s-08' "$rec08" >"$R9/.lock/token"
  touch -t 202001010000 "$R9/.lock/token"
  lock_abandonado_romper "$R9/.lock" 1 prueba-auto >/dev/null 2>&1 \
    && fail "(9f6d) la ruta automatica robo un lock con pid vivo (etime $et)"
  out9d=$(PATH="$T/bin08:$PATH" lock_recuperar_explicito "$R9/.lock" 1 prueba 2>&1); rc9d=$?
  kill "$rec08" 2>/dev/null; wait "$rec08" 2>/dev/null
  [ "$rc9d" -eq 0 ] || fail "(9f6d) con etime $et debio recuperar el reciclado (rc=$rc9d):
$out9d"
  [ -d "$R9/.lock" ] && fail "(9f6d) la explicita dejo el lock puesto con etime $et:
$out9d"
  printf '%s' "$out9d" | grep -qi 'reciclado' \
    || fail "(9f6d) la clasificacion con etime $et debio decir reciclado:
$out9d"
done
unset CORR_LOCK_VIEJO

# (9g) el trap del lock se desarma tras soltarlo: el EXIT de quien lo uso no puede
# romperle a otro un lock vivo tomado entremedias.
cat >"$T/z2.sh" <<Z2
. "$PWD/scripts/mac/corrida/lib.sh"
lock_tomar "$T/corridas/t1/registro.json" || exit 9
lock_soltar "$T/corridas/t1/registro.json"
t="\$(trap -p EXIT)"
[ -z "\$t" ] && echo DESARMADO || echo ARMADO
Z2
desarmado="$(bash "$T/z2.sh")"
[ "$desarmado" = "DESARMADO" ] || fail "el trap del lock quedo armado tras soltarlo"

# (9g2) el guard de trap ajeno: lock_tomar NUNCA pisa el EXIT del script que llama
# (mutarlo a "if true" deja este caso en rojo: el trap dueno deja de correr).
cat >"$T/z4.sh" <<Z4
. "$PWD/scripts/mac/corrida/lib.sh"
trap 'echo TRAP-DUENO-CORRIO' EXIT
lock_tomar "$T/corridas/t1/registro.json" || exit 9
lock_soltar "$T/corridas/t1/registro.json"
Z4
out_z4="$(bash "$T/z4.sh")"
[ "$out_z4" = "TRAP-DUENO-CORRIO" ] || fail "lock_tomar piso el trap del script que llama (salio: '$out_z4')"

# (9h) repro del reviewer: la carrera lanzar/cerrar. Con cerrar entrando mientras
# lanzar sondea la barra del CLI lento, NUNCA queda sesion viva y marcada en un
# registro cerrado: o lanzar se niega, o la sesion entra y cerrar la desmarca.
bash "$CORR" abrir t-tarde --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-tarde fallo"
bash "$CORR" lanzar-sesion t-tarde carril tarde "$T/ses" --nombre ses-tarde --encargo "$T/encargo.txt" >"$T/lanzar-tarde.out" 2>&1 &
plan=$!
sleep 0.8
bash "$CORR" cerrar t-tarde >/dev/null 2>&1 || fail "cerrar t-tarde fallo"
wait "$plan"; rc_l=$?
if [ "$rc_l" -ne 0 ]; then
  grep -q "se cerro mientras se lanzaba" "$T/lanzar-tarde.out" \
    || fail "la negativa no explica la carrera"
  "$TM_REAL" -L "$L" has-session -t "=ses-tarde" 2>/dev/null \
    && fail "ses-tarde quedo viva tras fallar su lanzamiento"
else
  "$TM_REAL" -L "$L" show-environment -t "=ses-tarde" OPENCLAW_WATCH >/dev/null 2>&1 \
    && fail "ses-tarde quedo marcada despues de que cerrar gano la serializacion"
fi
grep -q '"estado": *"cerrada"' "$T/corridas/t-tarde/registro.json" || fail "t-tarde no quedo cerrada"

# (9h2) JB: la carrera cerrar x lanzar con la red lenta bajo el lock: con el lease
# refrescado, lanzar ESPERA (no roba) y la corrida cerrada no registra sesiones.
# Umbral 3 s; cerrar tarda rm 2 s + envio 4 s; lanzar entra a los ~3.8 s, cuando el
# lock sin refresco ya seria viejo (mutacion: lo roba, registra y la prueba muere).
bash "$CORR" abrir t-jb --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-jb fallo"
CORR_LOCK_VIEJO=3 CRON_RM_SUENIO=2 MSJ_SUENIO=4 bash "$CORR" cerrar t-jb >/dev/null 2>&1 &
cerrajb=$!
sleep 3.5
CORR_LOCK_VIEJO=3 bash "$CORR" lanzar-sesion t-jb carril bueno "$T/ses" --nombre ses-jb >"$T/jb-lanzar.out" 2>&1 &
lanjb=$!
wait "$cerrajb"; rc_c=$?
wait "$lanjb"; rc_l=$?
[ "$rc_c" -eq 0 ] || fail "cerrar con red lenta debio cerrar (rc=$rc_c)"
[ "$rc_l" -ne 0 ] || fail "lanzar debio negarse sobre la corrida que se cerraba"
grep -q '"nombre": *"ses-jb"' "$T/corridas/t-jb/registro.json" \
  && fail "ses-jb quedo registrada en corrida cerrada (lock robado en vivo)"
grep -q '"estado": *"cerrada"' "$T/corridas/t-jb/registro.json" || fail "t-jb no quedo cerrada"
"$TM_REAL" -L "$L" has-session -t "=ses-jb" 2>/dev/null && fail "ses-jb quedo viva en corrida cerrada"

# (9i) 9.16: cerrar espera de forma acotada a un lanzamiento lento sin pedir
# reintento manual. Determinista y sin depender del reloj del sondeo: una
# sesion normal ya lanzada y marcada, mas un tomador que retiene el lock global
# 15 s (mas de los ~10 s que un intento suelto espera). Con el codigo actual
# cerrar falla pidiendo reintento; con el arreglo espera, desmarca y cierra.
bash "$CORR" abrir t-lento --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-lento fallo"
bash "$CORR" lanzar-sesion t-lento carril bueno "$T/ses" --nombre ses-lento --encargo "$T/encargo.txt" >/dev/null 2>&1 \
  || fail "lanzar ses-lento fallo (9.16)"
(
  trap - EXIT # no heredar el rm -rf $T de la prueba: lib.sh lo reinstalaria al soltar y este proceso borraria $T al salir
  CORRIDA_STATE="$T/corridas" TMUX_BIN="$T/bin/tmux-shim" OPENCLAW_BIN="$T/bin/openclaw"
  . scripts/mac/corrida/lib.sh
  marcas_lock_tomar || exit 1
  sleep 15
  marcas_lock_soltar
) &
retenedor=$!
i=0; while [ ! -d "$T/corridas/.marcas.lock" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
[ -d "$T/corridas/.marcas.lock" ] || fail "el retenedor no tomo el lock (9.16)"
bash "$CORR" cerrar t-lento >"$T/cerrar-lento.out" 2>&1 || fail "cerrar no espero al lanzamiento lento (9.16): $(cat "$T/cerrar-lento.out")"
wait "$retenedor"
grep -q '"estado": *"cerrada"' "$T/corridas/t-lento/registro.json" || fail "t-lento no quedo cerrada (9.16)"
"$TM_REAL" -L "$L" show-environment -t "=ses-lento" OPENCLAW_WATCH >/dev/null 2>&1 \
  && fail "ses-lento quedo marcada despues de cerrar (9.16)"
"$TM_REAL" -L "$L" has-session -t "=ses-lento" 2>/dev/null \
  || fail "ses-lento murio: cerrar solo desmarca, no mata (9.16)"

# (9i2) 9.16 acotada de verdad: con el lock ocupado y un tope chico, cerrar
# falla con diagnostico en vez de colgarse (no espera eterna ni exito falso).
bash "$CORR" abrir t-tope --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-tope fallo"
"$TM_REAL" -L "$L" new-session -d -s ses-tope -x 200 -y 50 >/dev/null 2>&1 || true
(
  trap - EXIT # no heredar el rm -rf $T de la prueba: lib.sh lo reinstalaria al soltar y este proceso borraria $T al salir
  CORRIDA_STATE="$T/corridas" TMUX_BIN="$T/bin/tmux-shim" OPENCLAW_BIN="$T/bin/openclaw"
  . scripts/mac/corrida/lib.sh
  marcas_lock_tomar || exit 1
  sleep 25
  marcas_lock_soltar
) &
holdeador=$!
i=0; while [ ! -d "$T/corridas/.marcas.lock" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
t0=$SECONDS
out="$(CORR_CIERRE_ESPERA=3 bash "$CORR" cerrar t-tope 2>&1)" && fail "cerrar debio fallar con tope 3 s y lock ocupado (9.16)"
[ $((SECONDS - t0)) -le 5 ] || fail "cerrar no respeto el tope de 3 s: tardo $((SECONDS - t0)) s (cada toma suelta no debe esperar ~10 s) (9.16)"
printf '%s' "$out" | grep -q "no cedio" || fail "cerrar no diagnostico la espera agotada (9.16): $out"
grep -q '"estado": *"abierta"' "$T/corridas/t-tope/registro.json" || fail "t-tope debio quedar abierta (9.16)"
wait "$holdeador"
bash "$CORR" cerrar t-tope >/dev/null 2>&1 || fail "cerrar tras liberar fallo (9.16)"

# (9i3) 9.16: con el tope ya vencido, cerrar igual prueba el lock una vez antes
# de rendirse (si el lock global se tomo cerca del limite, el del registro no
# falla en seco con 0 intentos). Lock libre = lo toma; lock ocupado = un solo
# intento y diagnostico, sin colgarse.
tope0libre=$(bash -c '. scripts/mac/corrida/lib.sh; n=0; toma() { n=$((n+1)); return 0; }
  CIERRE_TOPE=0 cerrar_esperar_lock "lock de prueba" toma; echo "rc=$? intentos=$n"')
[ "$tope0libre" = "rc=0 intentos=1" ] || fail "tope vencido + lock libre debio tomarlo al 1er intento (9.16): $tope0libre"
tope0dado=$(bash -c '. scripts/mac/corrida/lib.sh; n=0; toma() { n=$((n+1)); return 1; }
  CIERRE_TOPE=0 cerrar_esperar_lock "lock de prueba" toma 2>/dev/null; echo "rc=$? intentos=$n"')
[ "$tope0dado" = "rc=1 intentos=1" ] || fail "tope vencido + lock ocupado debio fallar con 1 intento (9.16): $tope0dado"

# (9i5) 9.16: el tope por defecto de cerrar queda por debajo del umbral de lock
# abandonado; si no, un lock fresco puede romperse al final de la espera.
( unset CORR_CIERRE_ESPERA CORR_LOCK_VIEJO; . scripts/mac/corrida/lib.sh
  [ "$CORR_CIERRE_ESPERA" -lt "$CORR_LOCK_VIEJO" ] ) \
  || fail "CORR_CIERRE_ESPERA por defecto debe ser menor que CORR_LOCK_VIEJO (9.16)"

# (9i6) 9.16: un lock tomado al empezar la espera no se rompe por envejecer
# durante ella. Lock manual (sin token) fresco, umbral de abandono 3 s y tope
# 7 s: a mitad de la espera cruza el umbral; cerrar debe rendirse, no romperlo.
bash "$CORR" abrir t-edad --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-edad fallo"
mkdir "$T/corridas/t-edad/.lock"
out="$(CORR_LOCK_VIEJO=3 CORR_CIERRE_ESPERA=7 bash "$CORR" cerrar t-edad 2>&1)" \
  && fail "cerrar rompio un lock que estaba tomado al empezar la espera (9.16): $out"
[ -d "$T/corridas/t-edad/.lock" ] || fail "el lock tomado al empezar desaparecio durante la espera (9.16)"
grep -q '"estado": *"abierta"' "$T/corridas/t-edad/registro.json" || fail "t-edad debio seguir abierta (9.16)"
rmdir "$T/corridas/t-edad/.lock"

# (9i4) 9.16: CORR_CIERRE_ESPERA se valida como segundos decimales: "08" son 8 s
# (no un octal invalido que rompa la aritmetica) y un valor no numerico se
# rechaza sin tocar nada.
bash "$CORR" abrir t-octal --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-octal fallo"
out="$(CORR_CIERRE_ESPERA=abc bash "$CORR" cerrar t-octal 2>&1)" && fail "cerrar acepto CORR_CIERRE_ESPERA=abc (9.16)"
printf '%s' "$out" | grep -q "no es un numero de segundos" || fail "CORR_CIERRE_ESPERA invalido sin diagnostico (9.16): $out"
grep -q '"estado": *"abierta"' "$T/corridas/t-octal/registro.json" || fail "t-octal debio seguir abierta tras el valor invalido (9.16)"
CORR_CIERRE_ESPERA=08 bash "$CORR" cerrar t-octal >/dev/null 2>&1 || fail "cerrar con CORR_CIERRE_ESPERA=08 fallo (octal) (9.16)"
grep -q '"estado": *"cerrada"' "$T/corridas/t-octal/registro.json" || fail "t-octal no quedo cerrada con 08 (9.16)"

# ancla de orden: cerrar toma el lock ANTES de listar sesiones (reordenarlo — la
# mutacion que deja la carrera abierta por el lado de cerrar — pone esto en rojo).
linelock=$(grep -n 'lock_tomar "$reg"' scripts/mac/corrida/cerrar.sh | head -1 | cut -d: -f1)
linelista=$(grep -n "get('sesiones'" scripts/mac/corrida/cerrar.sh | head -1 | cut -d: -f1)
[ -n "$linelock" ] && [ -n "$linelista" ] && [ "$linelock" -lt "$linelista" ] \
  || fail "cerrar lista sesiones antes de tomar el lock"

# (7) cerrar: todas las sesiones del registro desmarcadas, cron quitado por su id,
# CERRADA enviada, estado cerrada. Un nombre historico que ahora publica otro
# dueño se conserva intacto.
"$TM_REAL" -L "$L" set-environment -t "=ses-buena" OPENCLAW_WATCH_RUN otra \
  || fail "no se pudo preparar el nombre reutilizado para cerrar"
bash "$CORR" cerrar t1 >/dev/null || fail "cerrar fallo"
for s in $(CORR_REG="$T/corridas/t1/registro.json" python3 -c "
import json,os
print(' '.join(x.get('nombre','') for x in json.load(open(os.environ['CORR_REG'])).get('sesiones',[])))"); do
  [ "$s" = "ses-buena" ] && continue
  "$TM_REAL" -L "$L" show-environment -t "=$s" OPENCLAW_WATCH >/dev/null 2>&1 \
    && fail "cerrar debe desmarcar a $s"
done
"$TM_REAL" -L "$L" show-environment -t "=ses-buena" OPENCLAW_WATCH >/dev/null 2>&1 \
  || fail "cerrar retiro la marca de un nombre reutilizado por otra corrida"
[ "$("$TM_REAL" -L "$L" show-environment -t "=ses-buena" OPENCLAW_WATCH_RUN 2>/dev/null)" = "OPENCLAW_WATCH_RUN=otra" ] \
  || fail "cerrar retiro el dueño de un nombre reutilizado por otra corrida"
grep -q "cron rm" "$LLAMADAS" && fail "cerrar v2 toco un cron: el reloj global no se toca"
grep -q "CERRADA" "$T/corridas/t1/mensajes.jsonl" || fail "cerrar no anota CERRADA"
grep -q '"estado": *"cerrada"' "$T/corridas/t1/registro.json" || fail "el registro no cierra"

# (7b) el rm de un cron que ya no existe no ata: en v2 cerrar ni siquiera llama.
bash "$CORR" abrir t-fc --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-fc fallo"
out="$(CRON_RM_FAIL=1 bash "$CORR" cerrar t-fc 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "cerrar v2 no toca crons: un rm fallando no puede tumbarlo:
$out"
grep -q '"estado": *"cerrada"' "$T/corridas/t-fc/registro.json" || fail "t-fc no quedo cerrada"

# (7b2) repro del reviewer del kit: cerrar con el envio de CERRADA fallando.
# Primera corrida: rc!=0 CON mensaje que nombre la falla del envio (y que diga en
# que quedo la corrida); el reintento con envio sano cierra de verdad.
bash "$CORR" abrir t-ci --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-ci fallo"
bash "$CORR" lanzar-sesion t-ci carril bueno "$T/ses" --nombre ses-ci --encargo "$T/encargo.txt" >/dev/null \
  || fail "lanzar ses-ci fallo"
out="$(ENVIO_MODO=mal bash "$CORR" cerrar t-ci 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "cerrar con el envio fallando debio fallar"
printf '%s' "$out" | grep -q "aviso de cierre" || fail "el fallo del envio de CERRADA no se nombra"
printf '%s' "$out" | grep -q "reintentar" || fail "el fallo no dice en que quedo la corrida ni que reintentar cierra"
grep -q '"estado": *"abierta"' "$T/corridas/t-ci/registro.json" || fail "con el envio fallando el registro cerro a medias"
out="$(bash "$CORR" cerrar t-ci 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "el reintento de cerrar debio funcionar (rc=$rc):
$out"
grep -q '"estado": *"cerrada"' "$T/corridas/t-ci/registro.json" || fail "el reintento no cerro el registro"
"$TM_REAL" -L "$L" show-environment -t "=ses-ci" OPENCLAW_WATCH >/dev/null 2>&1 \
  && fail "tras el reintento ses-ci sigue marcada"

# (7b3) DA: cerrar sobre una corrida YA cerrada es no-op con confirmacion: rc=0,
# mensaje de cerrada, CERO reenvios del aviso y CERO toques al cron.
cerradas_antes=$(grep -c '"etiqueta": "CERRADA", "ok": true' "$T/corridas/t-ci/mensajes.jsonl")
crones_antes=$(grep -c "OPENCLAW cron" "$LLAMADAS")
out="$(bash "$CORR" cerrar t-ci 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "cerrar sobre una corrida cerrada debio ser rc=0"
printf '%s' "$out" | grep -q "cerrada t-ci" || fail "la segunda llamada no confirma el cierre"
cerradas_despues=$(grep -c '"etiqueta": "CERRADA", "ok": true' "$T/corridas/t-ci/mensajes.jsonl")
[ "$cerradas_antes" = "$cerradas_despues" ] || fail "la segunda llamada reenvio el aviso"
crones_despues=$(grep -c "OPENCLAW cron" "$LLAMADAS")
[ "$crones_antes" = "$crones_despues" ] || fail "la segunda llamada toco el cron"

# (7b4) DB: lock del registro tomado — el aviso NO sale antes del fallo; el fallo
# nombra el lock y lo hecho; el reintento cierra con UN solo aviso.
bash "$CORR" abrir t-lk --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-lk fallo"
bash "$CORR" lanzar-sesion t-lk carril bueno "$T/ses" --nombre ses-lk --encargo "$T/encargo.txt" >/dev/null \
  || fail "lanzar ses-lk fallo"
mkdir "$T/corridas/t-lk/.lock"
# Tope corto: cerrar se rinde mucho antes de que el lock manual (sin token) cumpla
# CORR_LOCK_VIEJO y sea rompible; asi el caso no depende de milisegundos (9.16).
out="$(CORR_CIERRE_ESPERA=3 bash "$CORR" cerrar t-lk 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con el lock tomado debio fallar"
printf '%s' "$out" | grep -q "lock" || fail "el fallo del lock no se nombra"
printf '%s' "$out" | grep -q "aviso NO salio" || fail "el fallo del lock no dice que el aviso no salio"
grep -q '"etiqueta": "CERRADA"' "$T/corridas/t-lk/mensajes.jsonl" 2>/dev/null \
  && fail "el aviso salio antes de fallar el lock"
grep -q '"estado": *"abierta"' "$T/corridas/t-lk/registro.json" || fail "con el lock tomado el registro cerro a medias"
rmdir "$T/corridas/t-lk/.lock"
bash "$CORR" cerrar t-lk >/dev/null || fail "el reintento debio cerrar"
grep -q '"estado": *"cerrada"' "$T/corridas/t-lk/registro.json" || fail "el reintento no cerro el registro"
n=$(grep -c '"etiqueta": "CERRADA", "ok": true' "$T/corridas/t-lk/mensajes.jsonl")
[ "$n" = "1" ] || fail "el reintento duplico el aviso (n=$n)"

# (7b5) DC: sin cron por corrida ya no hay lista que verificar en cerrar v2.
# La ilegibilidad de la lista se prueba del lado de migrar-seguimiento
# (test-corrida-seguimiento-global.sh): ahi si para todo.

# (7b6) EB: el aviso salio pero registro_escribir fallo (inyeccion: registro.json.tmp
# existe como directorio) — mensaje honesto de lo hecho/faltante y reintento SIN
# reenviar el aviso (mensajes.jsonl es la memoria).
bash "$CORR" abrir t-esc --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-esc fallo"
mkdir "$T/corridas/t-esc/registro.json.tmp"
out="$(bash "$CORR" cerrar t-esc 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con la escritura fallando debio fallar"
printf '%s' "$out" | grep -q "ya salio pero" || fail "el fallo de escritura no dice que el aviso ya salio"
grep -q '"estado": *"abierta"' "$T/corridas/t-esc/registro.json" || fail "con escritura fallando cerro a medias"
n=$(grep -c '"etiqueta": "CERRADA", "ok": true' "$T/corridas/t-esc/mensajes.jsonl")
[ "$n" = "1" ] || fail "el aviso debio salir exactamente una vez (n=$n)"
rmdir "$T/corridas/t-esc/registro.json.tmp"
bash "$CORR" cerrar t-esc >/dev/null || fail "el reintento debio cerrar"
grep -q '"estado": *"cerrada"' "$T/corridas/t-esc/registro.json" || fail "el reintento no cerro"
n=$(grep -c '"etiqueta": "CERRADA", "ok": true' "$T/corridas/t-esc/mensajes.jsonl")
[ "$n" = "1" ] || fail "el reintento reenvio el aviso (n=$n)"
grep -q "cron rm" "$LLAMADAS" && fail "cerrar t-esc toco un cron ajeno (ya no hay crons por corrida)"

# (7b7) FA: el canal de mensajes muerto no se viste de abierta — revert y error.
mkdir -p "$T/corridas/t-fa/mensajes.jsonl"
out="$(bash "$CORR" abrir t-fa --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con el canal de mensajes roto debio fallar"
printf '%s' "$out" | grep -q "canal de mensajes" || fail "el canal roto no se nombra"
[ -f "$T/corridas/t-fa/registro.json" ] && fail "con el canal roto el registro quedo escrito"
grep -q "cron add" "$LLAMADAS" && fail "abrir con el canal roto creo un cron"

# (7b8) GC: un envio colgado bajo el lock no deja el lock roto ni a cerrar
# colgado: el tope lo mata, el aviso queda sin salir y el lock se suelta
# (umbral inyectado a 3 s, stub duerme 12).
bash "$CORR" abrir t-gc --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-gc fallo"
out="$(MSJ_SUENIO=12 CORR_TOPE_RED=3 bash "$CORR" cerrar t-gc 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con el envio colgado debio fallar (rc=0)"
[ -d "$T/corridas/t-gc/.lock" ] && fail "el lock quedo puesto con el envio colgado"
printf '%s' "$out" | grep -q "aviso" || fail "el fallo con el envio colgado no nombra el aviso"
grep -q '"estado": *"abierta"' "$T/corridas/t-gc/registro.json" || fail "con el envio colgado cerro a medias"

# (7b9) HA: OPENCLAW_BIN inexistente — con_tope NO convierte el 127 en exito: cerrar
# falla cerrado y mensajes.jsonl no anota un CERRADA que nunca salio.
bash "$CORR" abrir t-ha --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-ha fallo"
out="$(OPENCLAW_BIN="/no/existe/openclaw" bash "$CORR" cerrar t-ha 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con el binario inexistente debio fallar cerrado"
printf '%s' "$out" | grep -q "aviso\|reintentar" || fail "el fallo con binario inexistente no se explica"
grep -q '"etiqueta": "CERRADA", "ok": true' "$T/corridas/t-ha/mensajes.jsonl" 2>/dev/null \
  && fail "anoto ok:true un aviso que nunca salio"
[ -d "$T/corridas/t-ha/.lock" ] && fail "el lock quedo puesto con el binario inexistente"

# (7b10) Sin lista que verificar en cerrar v2: la verificacion por lista vive
# en migrar-seguimiento (test-corrida-seguimiento-global.sh).

# (7b11) M-D: el envio inmediato tambien va con tope — un message send colgado
# muere al tope y el reporte es honesto (ok:false en mensajes.jsonl).
rc=0
( export CORR_TOPE_RED=3 MSJ_SUENIO=12
  corrida_mensaje t1 DETENIDA "2 de 2 partes terminadas" "quedo cubierto el envio con tope" "sigue lo demas del pase" "nada" >/dev/null 2>&1 ) \
  || rc=1
[ "$rc" -ne 0 ] || fail "un envio colgado debio morir al tope del reloj"
grep -q '"ok": false' "$T/corridas/t1/mensajes.jsonl" || fail "el envio muerto al tope no reporto honesto"

# (7c) lanzar sobre una corrida cerrada se niega.
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-zombi --encargo "$T/encargo.txt" >/dev/null 2>&1 \
  && fail "lanzar sobre una corrida cerrada debio negarse"
grep -q '"nombre": *"ses-zombi"' "$T/corridas/t1/registro.json" && fail "la sesion zombi quedo registrada"

# (8) el destino no aparece en ningun archivo bajo el repo (fuera de esta prueba, que lo define).
grep -r "$DESTINO" . --exclude-dir=.git --exclude=test-corrida-nucleo.sh >/dev/null 2>&1 \
  && fail "el destino se escribio en el repo"

# (10) sin cron hombre-muerto: abrir no crea crons y el registro declara el
# reloj global. El parte periodico lo pide el unico avance-tareas del director.
grep -q "cron add" "$LLAMADAS" && fail "abrir creo un cron por corrida"
grep -q '"schema": *"corrida.v2"' "$T/corridas/t1/registro.json" || fail "t1 no quedo v2"
grep -q '"seguimiento_global": *true' "$T/corridas/t1/registro.json" \
  || fail "t1 no declara el reloj global"
grep -q '"cron_vigia_id"' "$T/corridas/t1/registro.json" && fail "t1 conserva cron_vigia_id"

# (11) seguimiento.v1: NECESITO TU RESPUESTA y DETENIDA con notificacion;
# AVANZA acumula para el corte global sin mandar.
: > "$LLAMADAS"
corrida_mensaje t1 "NECESITO TU RESPUESTA" "1 de 2 partes terminadas" "un dialogo espera tu decision" \
  "Di sí o no, decide y contesta esta respuesta. Comando: ~/bin/x" "responder si o no" \
  || fail "el mensaje NECESITO TU RESPUESTA fallo"
necesito_linea="$(grep "message send" "$LLAMADAS" | tail -1)"
printf '%s' "$necesito_linea" | grep -q "NECESITO TU RESPUESTA" || fail "no salio la etiqueta NECESITO TU RESPUESTA"
printf '%s' "$necesito_linea" | grep -q -- "--silent" && fail "NECESITO TU RESPUESTA salio silenciosa"
printf '%s' "$necesito_linea" | grep -qF -- "-t $DESTINO" || fail "NECESITO TU RESPUESTA sin destino"
# t1 es una corrida de practica (simulacro=true, abierta en (0)): NINGUN campo
# del cuerpo (cambio, sigue, necesito) que trae el llamador se manda — ni
# siquiera "sigue", con un texto que a proposito pide una decision. Si se
# revierte el if de simulacro en corrida_mensaje, esto se pone rojo.
grep -q 'Comando: ' "$LLAMADAS" && fail "NECESITO TU RESPUESTA en practica mando un Comando: de referencia"
# El cuerpo son las lineas 2-4 del mensaje (linea 1 trae la etiqueta, que
# incluye literalmente la palabra "RESPUESTA" y no cuenta como pedido de
# decision del llamador).
cuerpo_necesito="$(tail -n +2 "$LLAMADAS")"
printf '%s' "$cuerpo_necesito" | grep -qiE 'Di s[ií]|decide|respuesta' \
  && fail "NECESITO TU RESPUESTA en practica dejo pasar un pedido de decision del llamador: $cuerpo_necesito"
grep -qF 'es una prueba, se resuelve sola' "$LLAMADAS" \
  || fail "NECESITO TU RESPUESTA en practica no avisa que se resuelve sola: $(cat "$LLAMADAS")"
grep -qF 'Nada que hacer: la prueba sigue sola.' "$LLAMADAS" \
  || fail "NECESITO TU RESPUESTA en practica no trae el sigue fijo: $(cat "$LLAMADAS")"
grep -qF 'responder si o no' "$LLAMADAS" \
  && fail "NECESITO TU RESPUESTA en practica mando el necesito real del llamador"
corrida_mensaje t1 DETENIDA "1 de 2 partes terminadas" "la corrida se detuvo por un percance" "se retoma cuando este claro" "nada" \
  || fail "el mensaje DETENIDA fallo"
detenida_linea="$(grep "message send" "$LLAMADAS" | tail -1)"
printf '%s' "$detenida_linea" | grep -q -- "--silent" && fail "DETENIDA salio silenciosa"
envios_antes=$(grep -c "message send" "$LLAMADAS")
corrida_mensaje t1 AVANZA "1 de 2 partes terminadas" "todo sigue en orden" "continua la misma parte" "nada" \
  || fail "AVANZA debio acumular"
[ "$(grep -c "message send" "$LLAMADAS")" = "$envios_antes" ] || fail "AVANZA mando en vez de acumular"
grep -q '"cambio": *"todo sigue en orden"' "$T/corridas/t1/eventos-seguimiento.jsonl" \
  || fail "AVANZA no dejo el evento acumulado"

# (11c) BUG DE PRODUCCION 2026-09-26: el vigia corre como LaunchAgent sin LANG
# ni LC_ALL. Sin locale, grep/sed/awk tratan los acentos como bytes sueltos y
# mensaje_valido rechazaba CUALQUIER mensaje acentuado ("Qué cambió:",
# "práctica"): en una corrida de practica, NECESITO TU RESPUESTA nunca salia
# ("mensaje fuera de contrato"). t1 sigue siendo la corrida de practica
# abierta en (0); esta llamada corre bajo el mismo entorno pelado que un
# LaunchAgent (env -i, sin LANG ni LC_ALL).
: > "$LLAMADAS"
env -i PATH="$T/bin:/opt/homebrew/bin:/usr/bin:/bin" HOME="$HOME" CORRIDA_STATE="$T/corridas" \
  OPENCLAW_BIN="$T/bin/openclaw" \
  bash -c '. scripts/mac/corrida/lib.sh
corrida_mensaje t1 "NECESITO TU RESPUESTA" "1 de 2 partes terminadas" "x" "y" "z"' \
  || fail "sin LANG/LC_ALL, corrida_mensaje de practica fallo (mensaje fuera de contrato por el locale)"
grep -qF 'es una prueba, se resuelve sola' "$LLAMADAS" \
  || fail "sin LANG/LC_ALL, el mensaje de practica no salio con su texto acentuado: $(cat "$LLAMADAS")"

# (11b) el despachador no carga lib ni subcomandos con ruta.
out="$(bash "$CORR" lib 2>&1)"; rc=$?
[ "$rc" -eq 2 ] || fail "corrida.sh lib debio rechazarse con rc 2 (rc=$rc)"
printf '%s' "$out" | grep -q "subcomando" || fail "el rechazo de lib no dice subcomando"

# (11c) el TUI de mentira pinta su pantalla y muere con kill-session.
"$TM_REAL" -L "$L" new-session -d -s tui-falso-test -c "$T/tui" bash "$PWD/scripts/tests/fixtures/tui-falso.sh" "$T/tui" \
  || fail "no arranco el TUI de mentira"
sleep 0.6
printf 'ESCENARIO-9X\n' >"$T/tui/pantalla.txt"
sleep 0.6
cap="$("$TM_REAL" -L "$L" capture-pane -p -t "=tui-falso-test:")"
printf '%s' "$cap" | grep -q "ESCENARIO-9X" || fail "el TUI no pinta el contenido de pantalla.txt"
printf '%s' "$cap" | grep -q "TUI-FALSO" || fail "el TUI no pinta su linea final"
"$TM_REAL" -L "$L" kill-session -t "=tui-falso-test" 2>/dev/null

# (12) Fase 14 Task 3: lanzar con --carril/--worker persiste worker,
# harness, provider, reported_model y session antes de entregar; si la
# entrega falla, persiste failed y detiene la sesion sin borrar su historial.
# El carril llega preparado por preparar-carril (reserva completa); lanzar
# sobre un carril inexistente o incompleto es error duro sin escritura parcial.
# (t1 ya cerro en (10): este bloque abre su propia corrida.)
. scripts/mac/corrida/lib.sh
# Un dir real y distinto por carril: el validador prohibe worktrees
# compartidos y lanzar exige el dir == worktree reservado.
mkdir -p "$T/wt-9x" "$T/wt-9y" "$T/wt-9a" "$T/wt-9b" "$T/wt-9w" "$T/wt-9L" \
  || fail "no se crearon worktrees del bloque carril"
bash "$CORR" abrir t-carril --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" --simulacro >/dev/null \
  || fail "abrir t-carril fallo"
python3 - "$T/corridas/t-carril/registro.json" "$T/wt-9x" "$T/wt-9y" "$T/wt-9a" "$T/wt-9b" "$T/wt-9w" "$T/wt-9L" <<'PY' || fail "no se preparo el carril lane-9x"
import json,sys
r=sys.argv[1]
W9=sys.argv[2]
W9Y,W9A,W9B,W9W,W9L=sys.argv[3],sys.argv[4],sys.argv[5],sys.argv[6],sys.argv[7]
d=json.load(open(r))
def reserva(lane,wt,base,**kw):
  c={'branch':'carril/'+lane,'worktree':wt,'base_remote_sha':base,'owner':lane,'mode':'write','estado':'reservado'}
  c.update(kw)
  return c
d.setdefault('carriles',{})['lane-9x']=reserva('lane-9x',W9,'0'*40)
d['carriles']['lane-9y']=reserva('lane-9y',W9Y,'1'*40)
d['carriles']['lane-9a']=reserva('lane-9a',W9A,'2'*40,estado='activo',worker='claude',session='ses-vieja-9')
d['carriles']['lane-9b']=reserva('lane-9b',W9B,'3'*40)
d['carriles']['lane-9w']=reserva('lane-9w',W9W,'4'*40)
d['carriles']['lane-9L']=reserva('lane-9L',W9L,'5'*40)
json.dump(d,open(r,'w'),indent=1)
PY
S9=$(bash "$CORR" lanzar-sesion t-carril carril bueno "$T/wt-9x" --nombre ses-carril-9 --encargo "$T/encargo.txt" --carril lane-9x --worker claude) \
  || fail "lanzar con carril fallo"
[ "$S9" = "ses-carril-9" ] || fail "la sesion del carril se llama $S9"
for campo in '"worker": *"claude"' '"harness": *"claude-code"' '"provider": *"anthropic"' '"reported_model": *"unknown"' '"session": *"ses-carril-9"' '"estado": *"activo"'; do
  grep -q "$campo" "$T/corridas/t-carril/registro.json" || fail "el carril no persiste $campo"
done
validar_registro "$T/corridas/t-carril/registro.json" || fail "el registro con el carril lanzado no pasa validar_registro"
export SWALLOW=1 SWALLOW_N=2 SWALLOW_SES=ses-carril-9f
rm -f "$T/tragado"
bash "$CORR" lanzar-sesion t-carril carril bueno "$T/wt-9y" --nombre ses-carril-9f --encargo "$T/encargo.txt" --carril lane-9y --worker codex >/dev/null 2>&1 \
  && fail "con la caja sin vaciarse, el carril debio fallar"
unset SWALLOW SWALLOW_N SWALLOW_SES
"$TM_REAL" -L "$L" has-session -t "=ses-carril-9f" 2>/dev/null && fail "la sesion del carril fallido quedo viva"
python3 - "$T/corridas/t-carril/registro.json" <<'PY' || fail "el carril fallido no persiste failed con historial"
import json,sys
c=json.load(open(sys.argv[1]))['carriles']['lane-9y']
assert c['estado']=='failed', c
assert c['worker']=='codex' and c['session']=='ses-carril-9f', c
PY
grep -q '"nombre": *"ses-carril-9f"' "$T/corridas/t-carril/registro.json" && fail "la sesion fallida del carril quedo en sesiones"
bash "$CORR" lanzar-sesion t-carril carril bueno "$T/ses" --nombre ses-carril-9g --carril lane-9z >/dev/null 2>&1 \
  && fail "--carril sin --worker debio rechazarse"
bash "$CORR" lanzar-sesion t-carril carril bueno "$T/ses" --nombre ses-carril-9h --carril lane-9z --worker nosuch >/dev/null 2>&1 \
  && fail "--worker desconocido debio rechazarse"
out="$(bash "$CORR" lanzar-sesion t-carril carril bueno "$T/ses" --nombre ses-carril-9r --encargo "$T/encargo.txt" --carril lane-9xq --worker claude 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "lanzar sobre un carril sin preparar debio rechazarse"
printf '%s' "$out" | grep -q "no esta preparado" || fail "el rechazo del carril sin preparar no se explica: $out"
"$TM_REAL" -L "$L" has-session -t "=ses-carril-9r" 2>/dev/null && fail "la sesion del carril sin preparar quedo viva"
python3 - "$T/corridas/t-carril/registro.json" <<'PY' || fail "el carril rechazado dejo escritura parcial"
import json,sys
assert 'lane-9xq' not in json.load(open(sys.argv[1])).get('carriles',{}), 'escritura parcial'
PY
# Fail-fast (M1 ai-review): el carril sin preparar se rechaza ANTES de crear
# la sesion: la CLI no spawnea en un directorio no autorizado. Sin el
# fail-fast, new-session queda en la bitacora del shim aunque luego se mate.
: >"$TMUX_LOG"
out="$(bash "$CORR" lanzar-sesion t-carril carril bueno "$T/ses" --nombre ses-carril-9q --encargo "$T/encargo.txt" --carril lane-9xq --worker claude 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "fail-fast: carril sin preparar aceptado"
grep -q "new-session -d -s ses-carril-9q" "$TMUX_LOG" && fail "fail-fast: el carril sin preparar spawneo sesion"

# Un carril ya activo no acepta otra sesion (repro del reviewer: segundo
# lanzamiento sobre el mismo carril).
out="$(bash "$CORR" lanzar-sesion t-carril carril bueno "$T/wt-9a" --nombre ses-carril-9a2 --encargo "$T/encargo.txt" --carril lane-9a --worker claude 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "lanzar sobre un carril activo aceptado"
printf '%s' "$out" | grep -q "no esta reservado" || fail "el rechazo del carril activo no se explica: $out"
"$TM_REAL" -L "$L" has-session -t "=ses-carril-9a2" 2>/dev/null && fail "la sesion del carril activo quedo viva"
# El dir debe ser el worktree reservado: otro dir existente se rechaza sin
# escritura (el repo principal o el worktree de otro carril no cuelan).
out="$(bash "$CORR" lanzar-sesion t-carril carril bueno "$T/tui" --nombre ses-carril-9b2 --encargo "$T/encargo.txt" --carril lane-9b --worker claude 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "lanzar fuera del worktree aceptado"
printf '%s' "$out" | grep -q "no es el worktree" || fail "el rechazo fuera del worktree no se explica: $out"
"$TM_REAL" -L "$L" has-session -t "=ses-carril-9b2" 2>/dev/null && fail "la sesion fuera del worktree quedo viva"
python3 - "$T/corridas/t-carril/registro.json" <<'PY' || fail "el rechazo fuera del worktree toco el carril"
import json,sys
c=json.load(open(sys.argv[1]))['carriles']['lane-9b']
assert c['estado']=='reservado' and 'session' not in c, c
PY
# Lock retenido a media carrera: el retenedor cae durante la entrega (que no
# necesita el lock) y la re-verificacion final no cede: sin sesion viva y
# rc != 0. Si la maquina lenta adelanta el retenedor, el rechazo es en el
# marcado: el mismo rc y la misma sesion muerta.
( trap - EXIT; sleep 1; mkdir "$T/corridas/t-carril/.lock" 2>/dev/null ) &
CORR_LOCK_INTENTOS=30 bash "$CORR" lanzar-sesion t-carril carril bueno "$T/wt-9L" --nombre ses-carril-9L --encargo "$T/encargo.txt" --carril lane-9L --worker claude >/dev/null 2>&1; rc=$?
wait 2>/dev/null
rmdir "$T/corridas/t-carril/.lock" 2>/dev/null
[ "$rc" -ne 0 ] || fail "con el lock retenido debio fallar"
"$TM_REAL" -L "$L" has-session -t "=ses-carril-9L" 2>/dev/null && fail "ses-carril-9L quedo viva con el lock retenido"
# Anotacion imposible (registro sin sesiones): el carril marca failed y la
# sesion muere (el fallo de escritura no deja activo fantasma).
bash "$CORR" abrir t-carril3 --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" --simulacro >/dev/null \
  || fail "abrir t-carril3 fallo"
python3 - "$T/corridas/t-carril3/registro.json" "$T/ses" <<'PY' || fail "no se preparo lane-3x"
import json,sys
r,wt=sys.argv[1],sys.argv[2]
d=json.load(open(r))
d['carriles']={'lane-3x':{'branch':'carril/lane-3x','worktree':wt,'base_remote_sha':'0'*40,
  'owner':'lane-3x','mode':'write','estado':'reservado'}}
del d['sesiones']
json.dump(d,open(r,'w'),indent=1)
PY
bash "$CORR" lanzar-sesion t-carril3 carril bueno "$T/ses" --nombre ses-carril-3x --carril lane-3x --worker claude >/dev/null 2>&1 \
  && fail "con la anotacion imposible debio fallar"
"$TM_REAL" -L "$L" has-session -t "=ses-carril-3x" 2>/dev/null && fail "ses-carril-3x quedo viva"
python3 - "$T/corridas/t-carril3/registro.json" <<'PY' || fail "el carril sin anotacion no marco failed"
import json,sys
assert json.load(open(sys.argv[1]))['carriles']['lane-3x']['estado']=='failed', 'sin failed'
PY
# Carrera cerrar x lanzar CON carril (mismo patron del repro 9h, ahora sobre
# lane-9w): cerrar espera al lanzamiento (CIERRE_ESPERA 45 s) y lo normal es
# que el lanzamiento gane y cerrar lo desmarque; si el cierre ganara, el
# carril marcaria failed. NUNCA queda sesion viva y marcada en un registro
# cerrado, en ninguna de las dos ramas.
bash "$CORR" lanzar-sesion t-carril carril tarde "$T/wt-9w" --nombre ses-carril-9w --encargo "$T/encargo.txt" --carril lane-9w --worker claude >"$T/lanzar-9w.out" 2>&1 &
plan9w=$!
sleep 0.8
bash "$CORR" cerrar t-carril >/dev/null 2>&1 || fail "cerrar t-carril fallo"
wait "$plan9w"; rc=$?
if [ "$rc" -ne 0 ]; then
  grep -q "se cerro mientras se lanzaba" "$T/lanzar-9w.out" || fail "la negativa del carril no explica la carrera"
  "$TM_REAL" -L "$L" has-session -t "=ses-carril-9w" 2>/dev/null && fail "ses-carril-9w quedo viva"
  python3 - "$T/corridas/t-carril/registro.json" <<'PY' || fail "lane-9w no marco failed"
import json,sys
c=json.load(open(sys.argv[1]))['carriles']['lane-9w']
assert c['estado']=='failed' and c['session']=='ses-carril-9w', c
PY
  grep -q '"nombre": *"ses-carril-9w"' "$T/corridas/t-carril/registro.json" && fail "ses-carril-9w quedo en sesiones"
else
  "$TM_REAL" -L "$L" show-environment -t "=ses-carril-9w" OPENCLAW_WATCH >/dev/null 2>&1 \
    && fail "ses-carril-9w quedo marcada despues de que cerrar gano la serializacion"
  python3 - "$T/corridas/t-carril/registro.json" <<'PY' || fail "lane-9w no quedo activo tras ganar la carrera"
import json,sys
c=json.load(open(sys.argv[1]))['carriles']['lane-9w']
assert c['estado']=='activo' and c['session']=='ses-carril-9w', c
PY
fi
grep -q '"estado": *"cerrada"' "$T/corridas/t-carril/registro.json" || fail "t-carril no quedo cerrada"
validar_registro "$T/corridas/t-carril/registro.json" || fail "tras el rechazo, el registro no pasa validar_registro"

echo "TODO VERDE: test-corrida-nucleo"
