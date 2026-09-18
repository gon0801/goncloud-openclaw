#!/bin/bash
# 9.2 abrir/lanzar-sesion/cerrar + corrida_mensaje, con tmux propio (-L) y CLIs de
# mentira. Ninguna prueba manda un Telegram real ni despierta a un agente vivo:
# OPENCLAW_BIN apunta a un stub que solo anota. Uso: bash scripts/tests/test-corrida-nucleo.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

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
chmod +x "$T/bin"/cli-bueno "$T/bin/cli-mala-barra"
export RECIBIDAS="$T/recibidas.txt"

# Tabla de modos propia de la prueba (el registro manda, no el entorno).
printf 'bueno\tcli-bueno\t--modo-bueno-9\tBARRITA-YOLO\t--\t--\t--\n' >"$T/modos.tsv"
printf 'malo\tcli-mala-barra\t--modo-malo-9\tBARRITA-YOLO\t--\t--\t--\n' >>"$T/modos.tsv"

# Stub openclaw: anota, no manda. El destino es unico para probar que no entra al repo.
# CRON_RM_FAIL=1 hace fallar cron rm; CRON_SIN_ID=1 hace que cron add no devuelva id
# (el job queda en la lista como par "nombre id" en cron-puesto: la limpieza debe
# resolver los ids ahi, todos los duplicados). LISTA_MALA=1 con LISTA_DESPUES_DE=n
# falla todo cron list despues del n-esimo.
LLAMADAS="$T/llamadas.log"
DESTINO="DESTINO-UNICO-9X"
cat >"$T/bin/openclaw" <<STUB
#!/bin/sh
printf '%s\n' "OPENCLAW \$*" >> "$LLAMADAS"
case "\$*" in
  *cron\ rm*)
    [ "\${CRON_RM_FAIL:-0}" = "1" ] && exit 1
    if ! grep -q " \$3\$" "$T/cron-puesto" 2>/dev/null; then exit 1; fi
    grep -v " \$3\$" "$T/cron-puesto" > "$T/cron-puesto.n" 2>/dev/null; mv "$T/cron-puesto.n" "$T/cron-puesto"
    printf '{}';;
  *cron\ list*)
    n=\$([ -f "$T/lists" ] && wc -l < "$T/lists" || echo 0); n=\$((n + 1)); echo x >> "$T/lists"
    if [ "\${LISTA_MALA:-0}" != "0" ] && [ "\$n" -gt "\${LISTA_DESPUES_DE:-0}" ]; then exit 1; fi
    printf '{"jobs":[{"name":"verif-sync-repos","delivery":{"to":"$DESTINO"}}'
    if [ "\${DEST_AMBIGUO:-0}" = "1" ]; then
      printf ',{"name":"verif-sync-repos","delivery":{"to":"OTRO-DESTINO-9Z"}}'
    fi
    if [ -f "$T/cron-puesto" ]; then
      while IFS= read -r linea; do
        [ -n "\$linea" ] && printf ',{"name":"%s","id":"%s"}' "\${linea%% *}" "\${linea#* }"
      done < "$T/cron-puesto"
    fi
    printf ']}';;
  *cron\ add*)
    nom=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--name" ] && nom="\$a"; prev="\$a"; done
    if [ "\${CRON_SIN_ID:-0}" = "1" ]; then
      c=\$(grep -c "^\$nom " "$T/cron-puesto" 2>/dev/null); c=\${c:-0}
      printf '%s %s\n' "\$nom" "cron-dup-\$nom-\$((c + 1))" >> "$T/cron-puesto"
      printf '{}'
    else
      printf '%s %s\n' "\$nom" "cron-1" >> "$T/cron-puesto"
      printf '{"id":"cron-1"}'
    fi;;
  *message\ send*) [ "\${ENVIO_MODO:-ok}" = "mal" ] && exit 1; printf '{"messageId":"m1"}';;
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
grep -q "cron add.*corrida-vigia-t1" "$LLAMADAS" || fail "abrir no crea el cron hombre-muerto"
grep -q '"simulacro": *true' "$T/corridas/t1/registro.json" || fail "el registro no dice simulacro"

# (0b) id invalido: nada de salir del directorio de estado ni inyectar comandos.
bash "$CORR" abrir '../fuga' --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 \
  && fail "abrir acepto un id con ../"
[ ! -e "$T/fuga" ] || fail "abrir escapo del directorio de estado con ../"
bash "$CORR" abrir 'a;b' --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 \
  && fail "abrir acepto un id con ;"

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
[ "$(grep -c "cron add.*corrida-vigia-t1" "$LLAMADAS")" = "1" ] || fail "abrir repetido duplico el cron"

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

# (6) simulacro: todo mensaje sale con prefijo; el texto enviado ES el del contrato.
corrida_mensaje t1 AVANZA "1 de 2 partes terminadas" "quedo lista la primera parte" "sigue la parte de mensajes" "nada" \
  || fail "el mensaje valido en simulacro fallo"
printf '[SIMULACRO] [AVANZA] Fase 9, 1 de 2 partes terminadas\nQue cambio: quedo lista la primera parte\nQue sigue: sigue la parte de mensajes\nQue necesito de ti: nada\n' >"$T/esp-sim.txt"
d=$(grep -n "OPENCLAW message send" "$LLAMADAS" | tail -1 | cut -d: -f1)
tail -n +"$d" "$LLAMADAS" | sed '1s/.* -m //' >"$T/obtenido.txt"
cmp -s "$T/esp-sim.txt" "$T/obtenido.txt" || fail "el texto enviado no es el de seguimiento.v1"

# (6b) el prefijo SIMULACRO de la primera linea no invalida; y no se reescribe el archivo.
printf '[SIMULACRO] [AVANZA] Fase 9, 1 de 2 partes terminadas\nQue cambio: quedo lista la primera parte\nQue sigue: sigue la parte de mensajes\nQue necesito de ti: nada\n' >"$T/prefijo.txt"
cp "$T/prefijo.txt" "$T/prefijo.orig"
mensaje_valido "$T/prefijo.txt" || fail "el prefijo SIMULACRO invalida un mensaje valido"
cmp -s "$T/prefijo.txt" "$T/prefijo.orig" || fail "mensaje_valido reescribe el archivo de quien llama"

# (6c) la ruta del cron es fisica y absoluta; una corrida NO simulacro no lleva prefijo.
mkdir -p "$T/c-real"
ln -s "$T/c-real" "$T/c-sym"
( cd "$T" && CORRIDA_STATE=c-sym bash "$CORR_ABS" abrir t-sym --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null ) \
  || fail "abrir con CORRIDA_STATE relativo fallo"
sym_line="$(grep "cron add.*corrida-vigia-t-sym" "$LLAMADAS" | head -1)"
printf '%s' "$sym_line" | grep -qF -- "$T/c-real/t-sym" || fail "el cron no cita la ruta fisica del estado"
bash "$CORR" abrir t-ns --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir sin simulacro fallo"
ns_line="$(grep "cron add.*corrida-vigia-t-ns" "$LLAMADAS" | head -1)"
printf '%s' "$ns_line" | grep -q "SIMULACRO" && fail "una corrida no simulacro lleva prefijo"

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

# (9c) nombre de sesion invalido: se rechaza antes de crear nada.
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre "con espacio" --encargo "$T/encargo.txt" >/dev/null 2>&1 \
  && fail "un nombre con espacio debio rechazarse"
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre "mai:l" >/dev/null 2>&1 \
  && fail "un nombre con : debio rechazarse"
"$TM_REAL" -L "$L" list-sessions -F '#{session_name}' 2>/dev/null | grep -q "mai:l" && fail "la sesion de nombre invalido se creo"

# (9d) el marcado que falla no deja sesion viva ni sin marca.
SETENV_FAIL=ses-marka bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-marka >/dev/null 2>&1 \
  && fail "con el marcado fallando debio fallar el lanzamiento"
"$TM_REAL" -L "$L" has-session -t "=ses-marka" 2>/dev/null && fail "la sesion sin marca quedo viva"
grep -q '"nombre": *"ses-marka"' "$T/corridas/t1/registro.json" && fail "la sesion sin marca quedo registrada"
unset SETENV_FAIL

# (9e) cron add sin id usable: abrir se niega, no escribe registro, y la limpieza
# resuelve los ids REALES en la lista (TODOS los duplicados homonimos) y dice la
# verdad cuando no puede verificar.
CRON_SIN_ID=1 bash "$CORR" abrir t-sinid --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 \
  && fail "cron add sin id debio reventar abrir"
[ -f "$T/corridas/t-sinid/registro.json" ] && fail "abrir escribio registro sin id de cron"
out="$(CRON_SIN_ID=1 bash "$CORR" abrir t-sinid --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"
printf '%s' "$out" | grep -q "id" || fail "el fallo del cron sin id no dice nada"
grep -q "cron rm cron-dup-corrida-vigia-t-sinid-1" "$LLAMADAS" || fail "la limpieza sin id no borro por el id de la lista"
# dos jobs homonimos (medido en vivo por el lead): la corrida que los deja debe
# quitarlos a los DOS y reportar cuantos.
CRON_SIN_ID=1 CRON_RM_FAIL=1 bash "$CORR" abrir t-dup --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null 2>&1 \
  && fail "abrir t-dup con rm fallando debio fallar"
out="$(CRON_SIN_ID=1 bash "$CORR" abrir t-dup --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"
grep -q "cron rm cron-dup-corrida-vigia-t-dup-1" "$LLAMADAS" && grep -q "cron rm cron-dup-corrida-vigia-t-dup-2" "$LLAMADAS" \
  || fail "con dos crons homonimos no se quitaron los dos"
printf '%s' "$out" | grep -q "2 job" || fail "el informe no dice cuantos jobs quito"
# lista ilegible tras el rm: no informa 'se quito' sin haber verificado nada.
nl=$([ -f "$T/lists" ] && wc -l < "$T/lists" || echo 0)
out="$(CRON_SIN_ID=1 LISTA_MALA=1 LISTA_DESPUES_DE=$((nl + 2)) bash "$CORR" abrir t-ileg --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"
printf '%s' "$out" | grep -q "no se pudo" || fail "con la lista ilegible no dice la verdad"
printf '%s' "$out" | grep -q "se quito por la lista" && fail "con la lista ilegible informo una limpieza no verificada"
# y el ILEGIBLE del PRIMER cron_jobs_de: la lista cae justo ahi (la del destino
# paso, la relectura nunca llega) y el informe es honesto hasta el final.
nl=$([ -f "$T/lists" ] && wc -l < "$T/lists" || echo 0)
out="$(CRON_SIN_ID=1 LISTA_MALA=1 LISTA_DESPUES_DE=$((nl + 1)) bash "$CORR" abrir t-ileg2 --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con la lista ilegible de entrada debio fallar"
printf '%s' "$out" | grep -q "no se pudo leer la lista" || fail "la lista ilegible de entrada no se reporta honestamente"
printf '%s' "$out" | grep -q "se quito por la lista" && fail "la lista ilegible de entrada informo una limpieza inexistente"

# homonimos del canal con destinos DISTINTOS: abrir no elige, falla cerrado.
out="$(DEST_AMBIGUO=1 bash "$CORR" abrir t-amb --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "con destinos ambiguos debio fallar cerrado"
printf '%s' "$out" | grep -q "ambigu" || fail "el fallo por destinos ambiguos no lo dice"

# (9f) lock del registro: fresco espera y falla; viejo se rompe y se sigue.
. scripts/mac/corrida/lib.sh
mkdir "$T/corridas/t1/.lock"
registro_actualizar "$T/corridas/t1/registro.json" "d['timebox_horas']=6" >/dev/null 2>&1 \
  && fail "con lock fresco debio esperar y fallar"
rmdir "$T/corridas/t1/.lock"
mkdir "$T/corridas/t1/.lock"
touch -t 202001010000 "$T/corridas/t1/.lock"
registro_actualizar "$T/corridas/t1/registro.json" "d['timebox_horas']=6" >"$T/lock.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "con lock viejo debio recuperarse y escribir (rc=$rc)"
grep -q "lock" "$T/lock.out" || fail "romper el lock viejo no avisa"
[ -d "$T/corridas/t1/.lock" ] && fail "el lock viejo quedo puesto"

# (9g) el trap del lock se desarma tras soltarlo: el EXIT de quien lo uso no puede
# romperle a otro un lock vivo tomado entremedias.
cat >"$T/z2.sh" <<Z2
. "$PWD/scripts/mac/corrida/lib.sh"
registro_actualizar "$T/corridas/t1/registro.json" 'd["timebox_horas"]=6' || exit 9
t="\$(trap -p EXIT)"
[ -z "\$t" ] && echo DESARMADO || echo ARMADO
Z2
desarmado="$(bash "$T/z2.sh")"
[ "$desarmado" = "DESARMADO" ] || fail "el trap del lock quedo armado tras soltarlo"

# (7) cerrar: todas las sesiones del registro desmarcadas, cron quitado por su id,
# CERRADA enviada, estado cerrada.
bash "$CORR" cerrar t1 >/dev/null || fail "cerrar fallo"
for s in $(CORR_REG="$T/corridas/t1/registro.json" python3 -c "
import json,os
print(' '.join(x.get('nombre','') for x in json.load(open(os.environ['CORR_REG'])).get('sesiones',[])))"); do
  "$TM_REAL" -L "$L" show-environment -t "=$s" OPENCLAW_WATCH >/dev/null 2>&1 \
    && fail "cerrar debe desmarcar a $s"
done
grep -q "cron rm cron-1" "$LLAMADAS" || fail "cerrar no quito el cron por su id"
grep -q "CERRADA" "$T/corridas/t1/mensajes.jsonl" || fail "cerrar no anota CERRADA"
grep -q '"estado": *"cerrada"' "$T/corridas/t1/registro.json" || fail "el registro no cierra"

# (7b) cron rm que falla: cerrar se queja ruidosamente, no en silencio.
bash "$CORR" abrir t-fc --runbook "$RB" --vigia claw --cli-modos "$T/modos.tsv" >/dev/null \
  || fail "abrir t-fc fallo"
out="$(CRON_RM_FAIL=1 bash "$CORR" cerrar t-fc 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "cerrar trago el fallo del cron rm"
printf '%s' "$out" | grep -q "cron" || fail "el fallo del cron rm no dice nada"

# (7b2) repro del reviewer del kit: cerrar con el envio de CERRADA fallando.
# Primera corrida: rc!=0 CON mensaje que nombre la falla del envio (y que diga en
# que quedo la corrida); el reintento con envio sano cierra de verdad, aunque el
# cron ya este quitado (cron rm de un id inexistente no lo ata).
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
grep -q "corrida-vigia-t-ci" "$T/cron-puesto" 2>/dev/null && fail "tras el reintento el cron sigue puesto"

# (7c) lanzar sobre una corrida cerrada se niega.
bash "$CORR" lanzar-sesion t1 carril bueno "$T/ses" --nombre ses-zombi --encargo "$T/encargo.txt" >/dev/null 2>&1 \
  && fail "lanzar sobre una corrida cerrada debio negarse"
grep -q '"nombre": *"ses-zombi"' "$T/corridas/t1/registro.json" && fail "la sesion zombi quedo registrada"

# (8) el destino no aparece en ningun archivo bajo el repo (fuera de esta prueba, que lo define).
grep -r "$DESTINO" . --exclude-dir=.git --exclude=test-corrida-nucleo.sh >/dev/null 2>&1 \
  && fail "el destino se escribio en el repo"

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
printf '%s' "$cron_line" | grep -q "dato, no instruccion" || fail "el cron no ensena la regla de pantalla-dato"
printf '%s' "$cron_line" | grep -q "el dueno" || fail "el cron no habla de el dueno"
printf '%s' "$cron_line" | grep -q "Comando: " || fail "el cron no cita el marcador Comando"
printf '%s' "$cron_line" | grep -q "David" && fail "el cron nombra a David en vez de el dueño"
grep -q '"cron_vigia_id"' "$T/corridas/t1/registro.json" || fail "el registro no guarda el id del cron"

# (11) seguimiento.v1: NECESITO TU RESPUESTA y DETENIDA con notificacion; lo rutinario callado.
: > "$LLAMADAS"
corrida_mensaje t1 "NECESITO TU RESPUESTA" "1 de 2 partes terminadas" "un dialogo espera tu decision" "la corrida sigue en marcha" "responder si o no" \
  || fail "el mensaje NECESITO TU RESPUESTA fallo"
necesito_linea="$(grep "message send" "$LLAMADAS" | tail -1)"
printf '%s' "$necesito_linea" | grep -q "NECESITO TU RESPUESTA" || fail "no salio la etiqueta NECESITO TU RESPUESTA"
printf '%s' "$necesito_linea" | grep -q -- "--silent" && fail "NECESITO TU RESPUESTA salio silenciosa"
printf '%s' "$necesito_linea" | grep -qF -- "-t $DESTINO" || fail "NECESITO TU RESPUESTA sin destino"
corrida_mensaje t1 DETENIDA "1 de 2 partes terminadas" "la corrida se detuvo por un percance" "se retoma cuando este claro" "nada" \
  || fail "el mensaje DETENIDA fallo"
detenida_linea="$(grep "message send" "$LLAMADAS" | tail -1)"
printf '%s' "$detenida_linea" | grep -q -- "--silent" && fail "DETENIDA salio silenciosa"
corrida_mensaje t1 AVANZA "1 de 2 partes terminadas" "todo sigue en orden" "continua la misma parte" "nada" \
  || fail "el mensaje AVANZA fallo"
avanza_linea="$(grep "message send" "$LLAMADAS" | tail -1)"
printf '%s' "$avanza_linea" | grep -q -- "--silent" || fail "AVANZA dejo de salir silencioso"

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

echo "TODO VERDE: test-corrida-nucleo"
