#!/bin/bash
# 9.2 abrir/lanzar-sesion/cerrar + corrida_mensaje, con tmux propio (-L) y CLIs de
# mentira. Ninguna prueba manda un Telegram real ni despierta a un agente vivo:
# OPENCLAW_BIN apunta a un stub que solo anota. Uso: bash scripts/tests/test-corrida-nucleo.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

CORR=scripts/mac/corrida.sh
[ -x "$CORR" ] || fail "falta $CORR"
TM_REAL="$(command -v tmux 2>/dev/null || true)"
[ -z "$TM_REAL" ] && [ -x /opt/homebrew/bin/tmux ] && TM_REAL=/opt/homebrew/bin/tmux
[ -n "$TM_REAL" ] || fail "sin tmux no hay prueba de sesiones"

T=$(mktemp -d) || exit 1
L="nucleo$$"
trap '"$TM_REAL" -L "$L" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ses"

# CLIs de mentira: pintan su barra y luego reciben el encargo por stdin.
cat >"$T/bin/cli-bueno" <<'CLI'
#!/bin/sh
echo "BARRITA-YOLO"
cat >> "$RECIBIDAS"
CLI
cat >"$T/bin/cli-mala-barra" <<'CLI'
#!/bin/sh
echo "OTRA-COSA"
cat >> "$RECIBIDAS"
CLI
chmod +x "$T/bin"/cli-bueno "$T/bin/cli-mala-barra"
export RECIBIDAS="$T/recibidas.txt"

# Tabla de modos propia de la prueba (el registro manda, no el entorno).
printf 'bueno\tcli-bueno\t--modo-bueno-9\tBARRITA-YOLO\t--\t--\t--\n' >"$T/modos.tsv"
printf 'malo\tcli-mala-barra\t--modo-malo-9\tBARRITA-YOLO\t--\t--\t--\n' >>"$T/modos.tsv"

# Stub openclaw: anota, no manda. El destino es unico para probar que no entra al repo.
LLAMADAS="$T/llamadas.log"
DESTINO="DESTINO-UNICO-9X"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
printf '%s\n' "OPENCLAW \$*" >> "$LLAMADAS"
case "\$*" in
  *cron\ list*) printf '{"jobs":[{"name":"verif-sync-repos","delivery":{"to":"$DESTINO"}}]}';;
  *cron\ add*) printf '{"id":"cron-1"}';;
  *cron\ rm*) printf '{}';;
  *message\ send*) printf '{"messageId":"m1"}';;
esac
exit 0
STUB
chmod +x "$T/bin/openclaw"

# Shim tmux: servidor propio + bitacora de llamadas; con SWALLOW=1 traga el primer Enter.
TMUX_LOG="$T/tmux.log"
cat >"$T/bin/tmux-shim" <<STUB
#!/bin/sh
printf '%s\n' "TMUX \$*" >> "$TMUX_LOG"
if [ "\${SWALLOW:-0}" = "1" ] && [ "\$*" = "send-keys -t \${SWALLOW_SES:-} Enter" ] && [ ! -f "$T/tragado" ]; then
  touch "$T/tragado"
  exit 0
fi
exec $TM_REAL -L $L "\$@"
STUB
chmod +x "$T/bin/tmux-shim"

export PATH="$T/bin:$PATH" CORRIDA_STATE="$T/corridas"
export OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux-shim"

# (0) abrir en simulacro: registro 600, dir 700, cron hombre-muerto, destino guardado.
bash "$CORR" abrir t1 --runbook runbook-x --vigia claw --cli-modos "$T/modos.tsv" --simulacro >/dev/null \
  || fail "abrir fallo"
permiso() { # $1 ruta: stat portable (macOS usa -f, Linux -c; en Linux stat -f no falla, asi que se elige por sistema)
  if [ "$(uname)" = "Darwin" ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}
[ -f "$T/corridas/t1/registro.json" ] || fail "sin registro"
[ "$(permiso "$T/corridas/t1")" = "700" ] || fail "el dir no queda 700"
[ "$(permiso "$T/corridas/t1/registro.json")" = "600" ] || fail "el registro no queda 600"
grep -q "cron add.*corrida-vigia-t1" "$LLAMADAS" || fail "abrir no crea el cron hombre-muerto"
grep -q '"simulacro": *true' "$T/corridas/t1/registro.json" || fail "el registro no dice simulacro"

# (1) lanzar bueno con encargo: vive, barra ok, entrega, registro la anota.
printf 'haz lo pedido y termina con LISTO\n' >"$T/encargo.txt"
: >"$TMUX_LOG"
S=$(bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-buena --encargo "$T/encargo.txt") \
  || fail "lanzar bueno fallo"
[ "$S" = "ses-buena" ] || fail "la sesion se llama $S"
grep -q "haz lo pedido" "$RECIBIDAS" || fail "el encargo no llego al CLI"
grep -q '"nombre": *"ses-buena"' "$T/corridas/t1/registro.json" || fail "el registro no anota la sesion"

# (2) la marca ocurre ANTES del primer send-keys (orden leido del log del shim).
marca=$(grep -n "set-environment -t ses-buena OPENCLAW_WATCH 1" "$TMUX_LOG" | head -1 | cut -d: -f1)
tecla=$(grep -n "send-keys -t ses-buena" "$TMUX_LOG" | head -1 | cut -d: -f1)
[ -n "$marca" ] && [ -n "$tecla" ] && [ "$marca" -lt "$tecla" ] \
  || fail "la marca no va antes del primer send-keys (marca=$marca tecla=$tecla)"

# (3) barra ausente: falla y no entrega nada a esa sesion.
: >"$TMUX_LOG"
bash "$CORR" lanzar-sesion t1 carril malo "$T/ses" --nombre ses-mala >/dev/null 2>&1 \
  && fail "con barra ausente debio fallar"
grep -q "send-keys -t ses-mala" "$TMUX_LOG" && fail "con barra ausente no se manda nada"

# (4) Enter tragado: reintenta y el encargo igual llega.
export SWALLOW=1 SWALLOW_SES=ses-traga
: >"$TMUX_LOG"; rm -f "$T/tragado"
S=$(bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-traga --encargo "$T/encargo.txt") \
  || fail "con Enter tragado debio reintentar y entregar"
n=$(grep -c "send-keys -t ses-traga Enter" "$TMUX_LOG")
[ "$n" -ge 2 ] || fail "no hubo reintento del Enter (n=$n)"
grep -q "haz lo pedido" "$RECIBIDAS" || fail "tras el reintento el encargo no llego"
unset SWALLOW SWALLOW_SES

# (5) jerga: corrida_mensaje la rechaza y no la manda.
. scripts/mac/corrida/lib.sh
corrida_mensaje t1 AVANZA "se integro el PR de mensajes" "sigue la politica" "nada" 2>/dev/null \
  && fail "el mensaje con jerga debio rechazarse"
grep -q "se integro el PR" "$LLAMADAS" && fail "la jerga nunca sale del stub"

# (6) simulacro: todo mensaje sale con prefijo y sigue pasando el validador.
corrida_mensaje t1 AVANZA "quedo lista la primera parte" "sigue la parte de mensajes" "nada" \
  || fail "el mensaje valido en simulacro fallo"
linea=$(grep "message send" "$LLAMADAS" | tail -1)
printf '%s' "$linea" | grep -q "SIMULACRO" || fail "en simulacro falta el prefijo"
printf '[AVANZA] Fase 9\nQue cambio: quedo lista la primera parte\nQue sigue: sigue la parte de mensajes\nQue necesito de ti: nada\n' >"$T/final.txt"
[ "$(wc -l < "$T/final.txt")" -eq 4 ] || fail "el texto final no trae 4 lineas"

# (7) cerrar: cero marcadas, cero crons, CERRADA enviada, estado cerrada.
bash "$CORR" cerrar t1 >/dev/null || fail "cerrar fallo"
"$TM_REAL" -L "$L" show-environment -t ses-buena OPENCLAW_WATCH >/dev/null 2>&1 \
  && fail "cerrar debe desmarcar ses-buena"
grep -q "cron rm.*corrida-vigia-t1" "$LLAMADAS" || fail "cerrar no quita el cron"
grep -q "CERRADA" "$T/corridas/t1/mensajes.jsonl" || fail "cerrar no anota CERRADA"
grep -q '"estado": *"cerrada"' "$T/corridas/t1/registro.json" || fail "el registro no cierra"

# (8) el destino no aparece en ningun archivo bajo el repo (fuera de esta prueba, que lo define).
grep -r "$DESTINO" . --exclude-dir=.git --exclude=test-corrida-nucleo.sh >/dev/null 2>&1 \
  && fail "el destino se escribio en el repo"

# (9) con el entorno vacio se usa la misma tabla del registro.
: >"$TMUX_LOG"
env -i PATH="$T/bin:/opt/homebrew/bin:/usr/bin:/bin" HOME="$HOME" CORRIDA_STATE="$T/corridas" \
  OPENCLAW_BIN="$T/bin/openclaw" TMUX_BIN="$T/bin/tmux-shim" RECIBIDAS="$T/recibidas.txt" \
  bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-vacia >/dev/null \
  || fail "con env -i fallo"
grep -q -- "--modo-bueno-9" "$TMUX_LOG" || fail "con env -i no se uso la tabla del registro"

# (10) el cron hombre-muerto pide el parte: texto que instruye a claw, cada 60 min, a Telegram.
cron_line="$(grep "cron add.*corrida-vigia-t1" "$LLAMADAS" | head -1)"
printf '%s' "$cron_line" | grep -q -- "--every 60m" || fail "el cron no es cada 60 min"
printf '%s' "$cron_line" | grep -q -- "--channel telegram" || fail "el cron no entrega por Telegram"
printf '%s' "$cron_line" | grep -qF -- "--to $DESTINO" || fail "el cron no lleva el destino del canal"
printf '%s' "$cron_line" | grep -qF -- "$T/corridas/t1" || fail "el cron no senala el directorio de estado de la corrida"
printf '%s' "$cron_line" | grep -q "Contesta SOLO con el parte" || fail "el cron no le pide el parte a claw"
printf '%s' "$cron_line" | grep -q "capture-pane" || fail "el cron no manda mirar las pantallas"
printf '%s' "$cron_line" | grep -q "NO LEE CODIGO" || fail "el cron no exige lenguaje de usuario"
printf '%s' "$cron_line" | grep -q "empieza tu parte con" || fail "en simulacro el cron no pide el prefijo"

# (11) seguimiento.v1: NECESITO TU RESPUESTA con notificacion; lo rutinario en silencio.
: > "$LLAMADAS"
corrida_mensaje t1 "NECESITO TU RESPUESTA" "un dialogo espera tu decision" "la corrida sigue en marcha" "responder si o no" \
  || fail "el mensaje NECESITO TU RESPUESTA fallo"
necesito_linea="$(grep "message send" "$LLAMADAS" | tail -1)"
printf '%s' "$necesito_linea" | grep -q "NECESITO TU RESPUESTA" || fail "no salio la etiqueta NECESITO TU RESPUESTA"
printf '%s' "$necesito_linea" | grep -q -- "--silent" && fail "NECESITO TU RESPUESTA salio silenciosa"
printf '%s' "$necesito_linea" | grep -qF -- "-t $DESTINO" || fail "NECESITO TU RESPUESTA sin destino"
corrida_mensaje t1 AVANZA "todo sigue en orden" "continua la misma parte" "nada" \
  || fail "el mensaje AVANZA fallo"
avanza_linea="$(grep "message send" "$LLAMADAS" | tail -1)"
printf '%s' "$avanza_linea" | grep -q -- "--silent" || fail "AVANZA dejo de salir silencioso"

echo "TODO VERDE: test-corrida-nucleo"
