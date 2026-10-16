#!/bin/bash
# 9.10 instalar-mac.sh: instala las herramientas de la Mac en un HOME de
# mentira con uid inyectado. Nada toca el HOME real ni launchd real: HOME,
# INSTALAR_UID, LAUNCHCTL_BIN y GIT_BIN se inyectan. El stub de git de los
# casos 1-6 simula el arbol integrado (la rama responde los blobs del arbol):
# asi la mecanica se prueba igual en una rama de carril (arbol != main) que en
# main; la ruta real por defecto se prueba en el caso (9).
# Uso: bash scripts/tests/test-instalar-mac.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

INST=scripts/mac/instalar-mac.sh
[ -f "$INST" ] || fail "falta $INST"
/bin/bash -n "$INST" || fail "$INST no parsea con /bin/bash"

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/casa"
mkdir -p "$HOME"
export INSTALAR_UID=59999
LAUNCHLOG="$T/launchctl.log"; export LAUNCHLOG
mkdir -p "$T/bin"
cat >"$T/bin/launchctl-falso" <<STUB
#!/bin/sh
printf '%s\n' "LAUNCHCTL \$*" >> "$LAUNCHLOG"
# print de la sucesion: con semilla en \$T/print-sucesion.txt esta cargada y su
# volcado es la semilla; sin semilla no esta cargada (exit 1). Otros print (el
# vigilante) siguen contestando cargado (exit 0).
if [ "\$1" = print ] && printf '%s\n' "\$*" | grep -q ai.goncloud.agent-work-sucesion; then
  if [ -f "$T/print-sucesion.txt" ]; then cat "$T/print-sucesion.txt"; exit 0; fi
  exit 1
fi
# bootstrap que falla N veces (N en \$T/fallar-bootstrap): simula un bootout que
# todavia no termino.
if [ "\$1" = bootstrap ] && [ -s "$T/fallar-bootstrap" ]; then
  n=\$(cat "$T/fallar-bootstrap"); [ "\$n" -gt 0 ] && { echo \$((n-1)) > "$T/fallar-bootstrap"; exit 5; }
fi
exit 0
STUB
chmod +x "$T/bin/launchctl-falso"
export LAUNCHCTL_BIN="$T/bin/launchctl-falso"
export REPO_ROOT="$PWD"
cat >"$T/bin/git-integrado" <<STUB
#!/bin/sh
ultimo=""
for a in "\$@"; do ultimo="\$a"; done
case "\$ultimo" in
  *:*)
    rel="\${ultimo#*:}"
    [ -n "\${REPO_ROOT:-}" ] && exec /usr/bin/git hash-object "\$REPO_ROOT/\$rel"
    ;;
esac
exec /usr/bin/git "\$@"
STUB
chmod +x "$T/bin/git-integrado"
export GIT_BIN="$T/bin/git-integrado"
# Casos 1-8: ref fija a HEAD (siempre resoluble, tambien en el checkout del CI sin
# origin/main); el stub responde los blobs del arbol. El caso (9) la suelta.
export INSTALAR_REF=HEAD

# (1) --dry-run no toca nada e imprime que haria, con el uid inyectado.
out="$(bash "$INST" --dry-run 2>&1)" || fail "dry-run fallo: $out"
[ -z "$(ls -A "$HOME")" ] || fail "dry-run escribio en HOME: $(ls -A "$HOME")"
printf '%s' "$out" | grep -q "tmux-activity-watch.sh" || fail "dry-run no anuncia tmux-activity-watch.sh"
printf '%s' "$out" | grep -q "gui/59999" || fail "dry-run no usa el uid inyectado (falta gui/59999)"

# (2) instala el conjunto completo.
out="$(bash "$INST" 2>&1)" || fail "instalar fallo: $out"
for f in agent-tmux.sh agent-tmux-shell.zsh tmux-activity-watch.sh claude-stop-openclaw-event.sh shot.sh tablero-trabajo.sh; do
  [ -f "$HOME/bin/$f" ] || fail "falta \$HOME/bin/$f"
done
[ -x "$HOME/bin/tablero-trabajo.sh" ] || fail "tablero-trabajo.sh quedo sin +x (claw lo corre directo)"
[ -x "$HOME/bin/progress-events.py" ] || fail "progress-events.py no quedo instalado y ejecutable"
for f in brief.py contexto.py contracts.py flota.py host.py lineas.py modelos.py native_gateway.py progress_bridge.py resources.py routing.py sesion.py spool.py cutover.py; do
  cmp -s "scripts/agent-work/$f" "$HOME/bin/agent-work/$f" || fail "agent-work/$f falta o difiere"
done
# La carpeta de datos del paquete (SUA-03): cada archivo, entera, competencia incluida.
for f in $(cd scripts/agent-work/contexto && find . -type f | sed 's|^\./||' | sort); do
  cmp -s "scripts/agent-work/contexto/$f" "$HOME/bin/agent-work/contexto/$f" || fail "agent-work/contexto/$f falta o difiere"
done
[ -f "$HOME/bin/agent-work/contexto/competencia/ingenieria/positiva.json" ] || fail "agent-work/contexto/competencia incompleta"
# El host instalado lee los datos de su carpeta: las adaptaciones que el manifiesto fija.
(cd / && python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import contexto; adaptaciones = contexto.leer_adaptaciones(); assert set(adaptaciones) == {\"opencode-run\", \"openclaw\"}, adaptaciones" "$HOME/bin/agent-work") >/dev/null 2>&1 \
  || fail "agent-work/contexto.py instalado no lee contexto/ instalado"
# routing.py importa brief.py: cada modulo instalado tiene que importar solo con lo instalado.
for f in "$HOME"/bin/agent-work/*.py; do
  m="$(basename "$f" .py)"
  (cd / && python3 -I -c "import sys; sys.path.insert(0, sys.argv[1]); import $m" "$HOME/bin/agent-work") >/dev/null 2>&1 \
    || fail "agent-work/$m.py instalado no importa con lo instalado"
done
[ -x "$HOME/bin/agent-work/cutover.py" ] || fail "cutover.py instalado sin +x"
PL="$HOME/Library/LaunchAgents/ai.goncloud.tmux-activity-watch.plist"
[ -f "$PL" ] || fail "falta el plist generado"
[ -f "$HOME/.tmux.conf" ] || fail "falta \$HOME/.tmux.conf"
grep -qF "source ~/bin/agent-tmux-shell.zsh" "$HOME/.zshrc" 2>/dev/null \
  || fail "falta la linea de source en .zshrc"
printf '%s' "$out" | grep -q "instalado" || fail "no imprime que quedo instalado"

# (3) el plist generado usa el HOME de mentira, sin rutas fijas (mutacion: /Users/dn a fuego).
grep -qF "$HOME/bin/tmux-activity-watch.sh" "$PL" || fail "el plist no apunta al HOME instalado"
grep -qF "/Users/dn" "$PL" && fail "el plist trae /Users/dn a fuego"

# (3b) la sucesion diaria de SUA-04 (4.3): sin R construido no se instala (B1); con el, sí.
PL2="$HOME/Library/LaunchAgents/ai.goncloud.agent-work-sucesion.plist"
[ ! -f "$PL2" ] || fail "sin R construido el plist de sucesion no debia instalarse"
printf '%s' "$out" | grep -q "sin R construido" || fail "no dijo que falta el R construido: $out"
mkdir -p "$HOME/dev/wt/r-sua02-c-gate" && printf 'x\n' > "$HOME/dev/wt/r-sua02-c-gate/openclaw.mjs"
out="$(bash "$INST" 2>&1)" || fail "instalar con R construido fallo: $out"
[ -f "$PL2" ] || fail "falta el plist de sucesion generado"
grep -qF "$HOME/dev/wt/r-sua02-c-gate" "$PL2" || fail "el plist de sucesion no trae AGENT_WORK_SUCESION_RUNTIME_SOURCE con el HOME"
grep -qF "AGENT_WORK_AVISOS" "$PL2" || fail "el plist de sucesion no prende los avisos (AGENT_WORK_AVISOS=1)"
grep -qF "$HOME/dev/wt/agent-work-host/scripts/agent-work/encargo.py" "$PL2" || fail "el plist de sucesion no corre encargo.py del checkout del host"
grep -qF "<string>diario</string>" "$PL2" || fail "el plist de sucesion no llama diario"
grep -qF "<integer>5</integer>" "$PL2" || fail "el plist de sucesion no es a las 05"
grep -qF "<integer>30</integer>" "$PL2" || fail "el plist de sucesion no es a las :30"
grep -qF "en_US.UTF-8" "$PL2" || fail "el plist de sucesion no fija LANG"
grep -qF "$HOME/Library/Logs/goncloud/agent-work-sucesion.log" "$PL2" || fail "el plist de sucesion no deja su log"
grep -qF "/Users/dn" "$PL2" && fail "el plist de sucesion trae /Users/dn a fuego"
grep -q "bootstrap gui/59999" "$LAUNCHLOG" || fail "no cargo la sucesion con gui/59999"
# Semilla del print de la sucesion: a partir de aqui el stub la reporta cargada
# con el runtime por omision, igual que el archivo instalado; las corridas
# siguientes no deben relanzarla (caso 5).
cat >"$T/print-sucesion.txt" <<SEMILLA
	domain = gui/59999 {
		"environment" => {
			"AGENT_WORK_SUCESION_RUNTIME_SOURCE" => "$HOME/dev/wt/r-sua02-c-gate"
		}
	}
SEMILLA

# (3c) F2 (ronda 3): AGENT_WORK_SUCESION_RUNTIME mueve el runtime del canario en
# el plist de sucesion generado; hoy la plantilla manda y el entorno se ignora.
export HOME="$T/casa3c"; mkdir -p "$HOME"
mkdir -p "$HOME/dev/wt/r-canario" && printf 'x\n' >"$HOME/dev/wt/r-canario/openclaw.mjs"
out="$(AGENT_WORK_SUCESION_RUNTIME="$HOME/dev/wt/r-canario" bash "$INST" 2>&1)" \
  || fail "instalar con runtime de canario propio fallo: $out"
PL2C="$HOME/Library/LaunchAgents/ai.goncloud.agent-work-sucesion.plist"
grep -qF "$HOME/dev/wt/r-canario" "$PL2C" || fail "el plist de sucesion no trae el runtime de AGENT_WORK_SUCESION_RUNTIME"
grep -qF "r-sua02-c-gate" "$PL2C" && fail "el plist de sucesion trae el runtime por omision pese al entorno"
grep -qF "/Users/dn" "$PL2C" && fail "el plist de sucesion trae /Users/dn a fuego"
export HOME="$T/casa"

# (4) el vigilante se carga con el uid inyectado.
grep -q "bootstrap gui/59999" "$LAUNCHLOG" || fail "no cargo el vigilante con gui/59999"

# (5) idempotente: segunda corrida no cambia bytes ni mtimes.
boot1="$(grep -c bootout "$LAUNCHLOG")"
suma1="$(find "$HOME" -type f | sort | xargs cksum | cksum)"
touch "$T/marca"; sleep 1
bash "$INST" >/dev/null 2>&1 || fail "segunda corrida fallo"
suma2="$(find "$HOME" -type f | sort | xargs cksum | cksum)"
[ -n "$suma1" ] || fail "la suma de bytes salio vacia (el hash no corrio)"
[ "$suma1" = "$suma2" ] || fail "la segunda corrida cambio bytes"
[ "$(grep -c bootout "$LAUNCHLOG")" = "$boot1" ] || fail "la segunda corrida reinicio el vigilante sin cambios"
[ -z "$(find "$HOME" -newer "$T/marca" -type f)" ] || fail "la segunda corrida toco mtimes: $(find "$HOME" -newer "$T/marca" -type f)"
nlineas="$(grep -c "source ~/bin/agent-tmux-shell.zsh" "$HOME/.zshrc")"
[ "$nlineas" -eq 1 ] || fail ".zshrc duplico la linea ($nlineas)"

# (5b) respaldo .anterior al reemplazar un archivo cambiado a mano.
echo MANO >>"$HOME/bin/shot.sh"
bash "$INST" >/dev/null 2>&1 || fail "reinstalar tras cambio a mano fallo"
grep -q MANO "$HOME/bin/shot.sh.anterior" 2>/dev/null || fail "no guardo .anterior del archivo reemplazado"
cmp -s "$HOME/bin/shot.sh" scripts/mac/shot.sh || fail "no restauro shot.sh desde la fuente"

# (5c) si el .anterior no se puede escribir, no se pisa el archivo cambiado a mano.
if [ "$(id -u)" != "0" ]; then
  echo MANO2 >>"$HOME/bin/shot.sh"
  rm -f "$HOME/bin/shot.sh.anterior"; mkdir "$HOME/bin/shot.sh.anterior"; chmod 500 "$HOME/bin/shot.sh.anterior"
  bash "$INST" >/dev/null 2>&1 && fail "instalo aunque no pudo respaldar .anterior"
  grep -q MANO2 "$HOME/bin/shot.sh" || fail "piso el cambio a mano sin respaldo"
  chmod 700 "$HOME/bin/shot.sh.anterior"; rm -rf "$HOME/bin/shot.sh.anterior"
  bash "$INST" >/dev/null 2>&1 || fail "reinstalar tras liberar .anterior fallo"
fi

# (5d) un cambio en el script del vigilante lo reinicia, y un bootstrap que falla
# una vez (bootout aun terminando) se reintenta hasta cargarlo.
echo "# mano" >>"$HOME/bin/tmux-activity-watch.sh"
echo 1 >"$T/fallar-bootstrap"
nb="$(grep -c bootstrap "$LAUNCHLOG")"
bash "$INST" >/dev/null 2>&1 || fail "no reintento el bootstrap tras un fallo"
[ "$(grep -c bootstrap "$LAUNCHLOG")" -ge $((nb + 2)) ] || fail "no reintento el bootstrap"
rm -f "$T/fallar-bootstrap"

# (5e) F3 (ronda 3): la sucesion cargada cuyo archivo instalado difiere del
# generado se recarga (bootout y bootstrap, como el vigilante); hoy basta con
# que este cargada y no se recarga.
printf 'viejo\n' >"$PL2"
bash "$INST" >/dev/null 2>&1 || fail "instalar con el plist de sucesion pisado fallo"
lin_bo="$(grep -n "bootout gui/59999/ai.goncloud.agent-work-sucesion" "$LAUNCHLOG" | tail -1 | cut -d: -f1)"
[ -n "$lin_bo" ] || fail "no recargo la sucesion: falta bootout gui/59999/ai.goncloud.agent-work-sucesion"
lin_bs="$(grep -n "bootstrap gui/59999.*ai.goncloud.agent-work-sucesion" "$LAUNCHLOG" | tail -1 | cut -d: -f1)"
[ -n "$lin_bs" ] || fail "no recargo la sucesion: falta el bootstrap tras el bootout"
[ "$lin_bs" -gt "$lin_bo" ] || fail "el bootstrap de la sucesion no va despues del bootout"
# el plist pisado vuelve a ser el generado (misma sustitucion que usa el script).
esp="$T/esp.plist"; esc="$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')"
sed "s|/Users/dn|$esc|g" scripts/mac/ai.goncloud.agent-work-sucesion.plist >"$esp"
cmp -s "$esp" "$PL2" || fail "el plist de sucesion pisado no volvio al generado"
rm -f "$esp"

# (5f) F3 (ronda 3): --verificar mira tambien lo cargado: un volcado print con
# runtime viejo falla nombrando el plist de sucesion; con el volcado sano, verde.
mv "$T/print-sucesion.txt" "$T/print-sucesion.sana"
printf 'domain = gui/59999 {\n\t"AGENT_WORK_SUCESION_RUNTIME_SOURCE" => "/Users/viejo/r-viejo"\n}\n' >"$T/print-sucesion.txt"
out="$(bash "$INST" --verificar 2>&1)" && fail "verificar paso con la sucesion cargada contra un runtime viejo"
printf '%s' "$out" | grep -q "ai.goncloud.agent-work-sucesion" || fail "verificar no nombra el plist de sucesion cargado viejo: $out"
mv "$T/print-sucesion.sana" "$T/print-sucesion.txt"
bash "$INST" --verificar >/dev/null 2>&1 || fail "verificar fallo con la sucesion cargada sana"

# (6) --verificar: verde instalado, rojo nombrando el archivo tocado o ausente.
bash "$INST" --verificar >/dev/null 2>&1 || fail "verificar fallo sobre instalacion sana"
echo MANO >>"$HOME/bin/agent-tmux.sh"
out="$(bash "$INST" --verificar 2>&1)" && fail "verificar paso con agent-tmux.sh modificado"
printf '%s' "$out" | grep -q "agent-tmux.sh" || fail "verificar no nombra el archivo modificado: $out"
rm "$HOME/bin/claude-stop-openclaw-event.sh"
out="$(bash "$INST" --verificar 2>&1)" && fail "verificar paso con archivo ausente"
printf '%s' "$out" | grep -q "claude-stop-openclaw-event.sh" || fail "verificar no nombra el archivo ausente: $out"

# (7) blob contra la rama: fuente adulterada no se instala (mutacion: sin comprobar blob).
export HOME="$T/casa2"; mkdir -p "$HOME"
cat >"$T/bin/git-adulterado" <<STUB
#!/bin/sh
case "\$*" in
  *rev-parse*tablero-trabajo.sh*) printf '0000000000000000000000000000000000000000\n';;
  *) exec "$T/bin/git-integrado" "\$@";;
esac
STUB
chmod +x "$T/bin/git-adulterado"
out="$(GIT_BIN="$T/bin/git-adulterado" bash "$INST" 2>&1)" && fail "instalo con blob adulterado"
printf '%s' "$out" | grep -q "tablero-trabajo.sh" || fail "no nombra el archivo con blob distinto: $out"
[ -e "$T/casa2/bin" ] && fail "escribio archivos antes de fallar el blob"

# (7b) blob contra la rama para contexto/: el paquete de datos no se instala adulterado
# (mutacion: fase_blobs sin el bucle de contexto).
export HOME="$T/casa2b"; mkdir -p "$HOME"
cat >"$T/bin/git-contexto" <<STUB
#!/bin/sh
case "\$*" in
  *rev-parse*contexto/poteto.v1.json*) printf '0000000000000000000000000000000000000000\n';;
  *) exec "$T/bin/git-integrado" "\$@";;
esac
STUB
chmod +x "$T/bin/git-contexto"
out="$(GIT_BIN="$T/bin/git-contexto" bash "$INST" 2>&1)" && fail "instalo con el blob de contexto adulterado"
printf '%s' "$out" | grep -q "contexto/poteto.v1.json" || fail "no nombra el blob distinto de contexto: $out"
[ -e "$T/casa2b/bin" ] && fail "escribio archivos antes de fallar el blob de contexto"

# (8) archivo ausente en la rama se declara y no aborta.
cat >"$T/bin/git-ausente" <<STUB
#!/bin/sh
case "\$*" in
  *rev-parse*shot.sh*) exit 1;;
  *) exec "$T/bin/git-integrado" "\$@";;
esac
STUB
chmod +x "$T/bin/git-ausente"
export HOME="$T/casa3"; mkdir -p "$HOME"
out="$(GIT_BIN="$T/bin/git-ausente" bash "$INST" 2>&1)" || fail "aborto por archivo ausente en la rama: $out"
printf '%s' "$out" | grep -qi "sin referencia" || fail "no declara el archivo ausente en la rama: $out"
[ -f "$T/casa3/bin/shot.sh" ] || fail "omitio instalar el archivo declarado"

# (9) ruta real por defecto: con git real y ref por defecto, el instalador es
# coherente con el estado del arbol. Si el arbol trae cambios sin integrar
# (carril), se niega nombrando el archivo y sin escribir nada (fail closed);
# si el arbol esta integrado, instala sano.
export HOME="$T/casa4"; mkdir -p "$HOME"
unset GIT_BIN INSTALAR_REF
out="$(bash "$INST" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s' "$out" | grep -qE "blob distinto|sin referencia|sin comprobacion" \
    || fail "se nego sin explicar el blob/rama: $out"
  [ -e "$T/casa4/bin" ] && fail "escribio antes de fallar el blob real"
else
  bash "$INST" --verificar >/dev/null 2>&1 || fail "instalo por defecto pero no verifica"
fi

# Ancla: la ref por defecto es la rama por defecto.
grep -qF 'INSTALAR_REF:-origin/main' "$INST" || fail "la ref por defecto no es origin/main"

echo "OK test-instalar-mac"
