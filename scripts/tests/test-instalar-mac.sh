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

# (2) instala el conjunto completo, y retira los LaunchAgents de la ruta
# muerta (encargos por CLI y vigía de R, G#350 F4) que una Mac instalada por
# versiones anteriores todavía tenga puestos: los descarga (bootout), borra
# su plist y el binario del vigía.
PL2VIEJA="$HOME/Library/LaunchAgents/ai.goncloud.agent-work-sucesion.plist"
PL3VIEJA="$HOME/Library/LaunchAgents/ai.goncloud.vigia-rebase-r.plist"
mkdir -p "$HOME/Library/LaunchAgents"
printf 'plist-viejo\n' >"$PL2VIEJA"
printf 'plist-viejo\n' >"$PL3VIEJA"
printf '#!/bin/sh\nexit 0\n' >"$HOME/bin/vigia-rebase-r.sh" 2>/dev/null || { mkdir -p "$HOME/bin" && printf '#!/bin/sh\nexit 0\n' >"$HOME/bin/vigia-rebase-r.sh"; }
chmod +x "$HOME/bin/vigia-rebase-r.sh"
out="$(bash "$INST" 2>&1)" || fail "instalar fallo: $out"
for f in agent-tmux.sh agent-tmux-shell.zsh tmux-activity-watch.sh claude-stop-openclaw-event.sh shot.sh tablero-trabajo.sh; do
  [ -f "$HOME/bin/$f" ] || fail "falta \$HOME/bin/$f"
done
grep -q "bootout gui/59999/ai.goncloud.agent-work-sucesion" "$LAUNCHLOG" \
  || fail "no descargo el LaunchAgent de sucesion con gui/59999 (G#350 F4)"
grep -q "bootout gui/59999/ai.goncloud.vigia-rebase-r" "$LAUNCHLOG" \
  || fail "no descargo el vigia de rebase de R con gui/59999 (G#350 F4)"
[ ! -e "$PL2VIEJA" ] || fail "el plist de sucesion viejo quedo sin borrarse (G#350 F4)"
[ ! -e "$PL3VIEJA" ] || fail "el plist del vigia viejo quedo sin borrarse (G#350 F4)"
[ ! -e "$HOME/bin/vigia-rebase-r.sh" ] || fail "bin/vigia-rebase-r.sh quedo sin retirarse (G#350 F4)"
[ -x "$HOME/bin/tablero-trabajo.sh" ] || fail "tablero-trabajo.sh quedo sin +x (claw lo corre directo)"
[ -x "$HOME/bin/progress-events.py" ] || fail "progress-events.py no quedo instalado y ejecutable"
for f in contexto.py proyeccion.py spool.py; do
  cmp -s "scripts/agent-work/$f" "$HOME/bin/agent-work/$f" || fail "agent-work/$f falta o difiere"
done
# El paquete chico de sistema_agentes que proyeccion.py importa (SUA-07 H0a).
for f in __init__.py derivar.py; do
  cmp -s "scripts/sistema_agentes/$f" "$HOME/bin/agent-work/sistema_agentes/$f" || fail "agent-work/sistema_agentes/$f falta o difiere"
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
PL="$HOME/Library/LaunchAgents/ai.goncloud.tmux-activity-watch.plist"
[ -f "$PL" ] || fail "falta el plist generado"
[ -f "$HOME/.tmux.conf" ] || fail "falta \$HOME/.tmux.conf"
grep -qF "source ~/bin/agent-tmux-shell.zsh" "$HOME/.zshrc" 2>/dev/null \
  || fail "falta la linea de source en .zshrc"
printf '%s' "$out" | grep -q "instalado" || fail "no imprime que quedo instalado"

# (3) el plist generado usa el HOME de mentira, sin rutas fijas (mutacion: /Users/dn a fuego).
grep -qF "$HOME/bin/tmux-activity-watch.sh" "$PL" || fail "el plist no apunta al HOME instalado"
grep -qF "/Users/dn" "$PL" && fail "el plist trae /Users/dn a fuego"

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

# (7c) blob contra la rama para sistema_agentes/ (SUA-07 H0a): derivar.py no se
# instala adulterado (mutacion: fase_blobs sin el bucle de sistema_agentes).
export HOME="$T/casa2s"; mkdir -p "$HOME"
cat >"$T/bin/git-sistema" <<STUB
#!/bin/sh
case "\$*" in
  *rev-parse*sistema_agentes/derivar.py*) printf '0000000000000000000000000000000000000000\n';;
  *) exec "$T/bin/git-integrado" "\$@";;
esac
STUB
chmod +x "$T/bin/git-sistema"
out="$(GIT_BIN="$T/bin/git-sistema" bash "$INST" 2>&1)" && fail "instalo con el blob de derivar.py adulterado"
printf '%s' "$out" | grep -q "derivar.py" || fail "no nombra el blob distinto de sistema_agentes: $out"
[ -e "$T/casa2s/bin" ] && fail "escribio archivos antes de fallar el blob de sistema_agentes"

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
