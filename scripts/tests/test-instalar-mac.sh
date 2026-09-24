#!/bin/bash
# 9.10 instalar-mac.sh: instala las herramientas de corrida en un HOME de
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
printf '%s' "$out" | grep -q "corrida.sh" || fail "dry-run no anuncia corrida.sh"
printf '%s' "$out" | grep -q "gui/59999" || fail "dry-run no usa el uid inyectado (falta gui/59999)"

# (2) instala el conjunto completo.
out="$(bash "$INST" 2>&1)" || fail "instalar fallo: $out"
for f in corrida.sh cli-modos.tsv agent-tmux.sh agent-tmux-shell.zsh tmux-activity-watch.sh claude-stop-openclaw-event.sh shot.sh; do
  [ -f "$HOME/bin/$f" ] || fail "falta \$HOME/bin/$f"
done
[ -x "$HOME/bin/corrida.sh" ] || fail "corrida.sh quedo sin +x"
ncorr="$(ls "$HOME/bin/corrida"/*.sh 2>/dev/null | wc -l)"
[ "$ncorr" -eq 12 ] || fail "corrida/ trae $ncorr .sh, se esperaban 12"
for f in abrir lanzar-sesion terminar-sesion reconciliar-marcas cerrar preflight estado latido responder seguimiento migrar-seguimiento lib; do
  [ -f "$HOME/bin/corrida/$f.sh" ] || fail "falta \$HOME/bin/corrida/$f.sh"
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

# (4) el latido viejo ni se copia ni se carga.
[ -e "$HOME/bin/corrida-latido.sh" ] && fail "copio un corrida-latido a bin"
ls "$HOME/Library/LaunchAgents/" | grep -q "corrida-latido" && fail "copio el plist del latido viejo"
grep -q "corrida-latido" "$LAUNCHLOG" 2>/dev/null && fail "cargo el latido viejo en launchd"
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
  *rev-parse*cli-modos.tsv*) printf '0000000000000000000000000000000000000000\n';;
  *) exec "$T/bin/git-integrado" "\$@";;
esac
STUB
chmod +x "$T/bin/git-adulterado"
out="$(GIT_BIN="$T/bin/git-adulterado" bash "$INST" 2>&1)" && fail "instalo con blob adulterado"
printf '%s' "$out" | grep -q "cli-modos.tsv" || fail "no nombra el archivo con blob distinto: $out"
[ -e "$T/casa2/bin/corrida.sh" ] && fail "escribio archivos antes de fallar el blob"

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
  [ -e "$T/casa4/bin/corrida.sh" ] && fail "escribio antes de fallar el blob real"
else
  bash "$INST" --verificar >/dev/null 2>&1 || fail "instalo por defecto pero no verifica"
fi

# Anclas: la ref por defecto es la rama por defecto, y el latido viejo no esta
# en el manifiesto (ni se copia ni se carga, en ningun modo).
grep -qF 'INSTALAR_REF:-origin/main' "$INST" || fail "la ref por defecto no es origin/main"
grep -v "^#" "$INST" | grep -q "corrida-latido" && fail "el instalador toca el latido viejo fuera de comentarios"

# El runbook de Fase 9 instala con este script y verifica con --verificar; no
# exige +x a los subcomandos de corrida/ (en git son 100644 y se cargan con `.`):
# un `test -x` sobre ellos marcaba FALTA en una instalacion sana.
RB9=docs/runbooks/autopilot-fase9.md
grep -Eq 'bash scripts/mac/instalar-mac\.sh[[:space:]]*&&[[:space:]]*$' "$RB9" \
  || fail "$RB9 no instala con instalar-mac.sh (encadenado con &&)"
grep -qF 'bash scripts/mac/instalar-mac.sh --verificar' "$RB9" \
  || fail "$RB9 no verifica con instalar-mac.sh --verificar"
grep -qF 'test -x "$HOME/bin/corrida/' "$RB9" \
  && fail "$RB9 exige +x a subcomandos de corrida/ que no son ejecutables"

echo "OK test-instalar-mac"
