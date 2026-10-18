#!/bin/bash
# Vigía de rebase del gateway (scripts/mac/vigia-rebase-r.sh): conducta real
# contra un repo git de juguete con "base" y "upstream" etiquetados, y npm y
# ssh doblados por PATH.
#
#   1. Al día (latest == base): sale 0 sin avisar.
#   2. Versión nueva con choques de código y de versión: avisa por Telegram con
#      los dos conteos bien, deja el reporte y la marca.
#   3. El mismo aviso no se repite: la marca de la versión manda.
#   4. ssh caído: no marca y sale != 0; la corrida siguiente reintenta. Con esa
#      misma versión se prueba el umbral: k > 10 cambia la recomendación.
#   5. npm caído: sale != 0 sin avisar y sin dejar marca.
#   6. npm colgado: el timeout lo mata y sale != 0.
#   7. VIGIA_SIN_AVISO: hace todo menos el ssh y la marca.
#   8. R queda intacto: HEAD, rama, status, ramas y worktrees idénticos antes y
#      después; el fetch solo puede sumar el tag nuevo.
#   9. El script es de solo lectura sobre R (nada de checkout/rebase/merge/
#      worktree) y el plist es válido, apunta al script y corre lunes 09:00.
# 10. La marca solo con envío confirmado: salida del CLI sin messageId no
#      marca y sale != 0; el reintento con messageId sí (G#345 F2).
# 11. Fetch roto (tag inexistente en origin): != 0 sin aviso ni marca (F1).
# 12. merge-tree roto (rc=2, doble de git): != 0 sin aviso ni marca; quitar el
#      guard de rc deja 11 y 12 en rojo (F1).
# 13. Base más nueva que latest (R adelante del canal): al día, sin aviso
#      (F3 / CR 4308463341).
# 14. merge-tree rc=1 sin archivos listados (renombre de directorio) NO es
#      "0 choques": reporte y aviso dicen conflicto no clasificable (CR
#      4308463348).
#
# Uso: bash scripts/tests/test-vigia-rebase-r.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
S="$REPO/scripts/mac/vigia-rebase-r.sh"
P="$REPO/scripts/mac/ai.goncloud.vigia-rebase-r.plist"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name prueba; git config --global user.email prueba@example.invalid
git config --global init.defaultBranch main

# Dobladores de npm y ssh por PATH.
mkdir -p "$SB/bin"
cat > "$SB/bin/npm" <<'E'
#!/bin/sh
[ -n "${FAKE_NPM_SLEEP:-}" ] && sleep "$FAKE_NPM_SLEEP"
[ -n "${FAKE_NPM_RC:-}" ] && [ "$FAKE_NPM_RC" != 0 ] && exit "$FAKE_NPM_RC"
printf '%s\n' "${FAKE_NPM_VERSION:-2026.1.1}"
E
cat > "$SB/bin/ssh" <<'E'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_SSH_LOG:?}"
# El CLI de openclaw soporta --json y contesta el messageId del mensaje
# entregado (verificado con `openclaw message send --help`, OpenClaw
# 2026.9.7). Telegram da el id como ENTERO (G#345 F7); FAKE_SSH_ID_TEXTO=1 lo
# da como cadena. FAKE_SSH_SIN_ID=1 contesta JSON sin messageId: envío sin
# confirmación.
if [ -n "${FAKE_SSH_SIN_ID:-}" ]; then
  printf '{"ok":true,"result":{}}\n'
elif [ -n "${FAKE_SSH_ID_TEXTO:-}" ]; then
  printf '{"ok":true,"result":{"messageId":"tg-falso-1"}}\n'
else
  printf '{"ok":true,"result":{"messageId":4242}}\n'
fi
exit "${FAKE_SSH_RC:-0}"
E
GIT_REAL="$(command -v git)"
cat > "$SB/bin/git" <<E
#!/bin/sh
if [ -n "\${FAKE_MERGETREE_RC:-}" ]; then
  for a in "\$@"; do
    # Silencio y rc: rc=1 sin salida simula el choque sin archivos listados
    # (renombre de directorio, CR 4308463348); rc>1, un merge-tree roto.
    [ "\$a" = "merge-tree" ] && exit "\$FAKE_MERGETREE_RC"
  done
fi
exec "$GIT_REAL" "\$@"
E
chmod +x "$SB/bin/npm" "$SB/bin/ssh" "$SB/bin/git"
SSH_LOG="$SB/llamadas-ssh.txt"; export SSH_LOG FAKE_SSH_LOG="$SSH_LOG"
: > "$SSH_LOG"

# Upstream público de juguete. Base v2026.1.1; los commits nuevos tocan los
# mismos archivos que nuestra rama para que el merge en memoria choque.
UP="$SB/upstream.git"; git init -q --bare "$UP"
W="$SB/semilla"; git init -q "$W"
printf '{\n "nombre": "x"\n}\n' > "$W/package.json"
mkdir -p "$W/src"
printf 'viejo\n' > "$W/src/gateway.ts"
git -C "$W" add . && git -C "$W" commit -qm base
git -C "$W" tag v2026.1.1
git -C "$W" push -q "$UP" main v2026.1.1

# R: clon del upstream que aún NO sabe de las versiones nuevas (el tag base
# viene por seguimiento automático; v2026.2.3 se empuja después del clon).
git clone -q "$UP" "$SB/r"
git -C "$SB/r" checkout -q -b feat/nuestra v2026.1.1
printf 'nuestro\n' > "$SB/r/src/gateway.ts"
printf '{\n "nombre": "x",\n "nuestro": 1\n}\n' > "$SB/r/package.json"
git -C "$SB/r" commit -qam nuestra

# Versión v2026.2.3: 3 commits públicos que chocan con lo nuestro en
# src/gateway.ts (código) y package.json (versión); CHANGELOG.md solo toca
# upstream, así que no choca y no debe salir en la lista.
git -C "$W" checkout -q -b upstream-trabajo main
for i in 1 2 3; do
  printf 'publico %s\n' "$i" > "$W/src/gateway.ts"
  printf '{\n "nombre": "x",\n "publico": %s\n}\n' "$i" > "$W/package.json"
  printf 'entrada %s\n' "$i" >> "$W/CHANGELOG.md"
  git -C "$W" add . && git -C "$W" commit -qm "publico$i"
done
git -C "$W" tag v2026.2.3
git -C "$W" push -q "$UP" upstream-trabajo:main v2026.2.3

# Estado de R antes de tocar nada (para el candado 8).
captura_R() {
  head0=$(git -C "$SB/r" rev-parse HEAD)
  rama0=$(git -C "$SB/r" rev-parse refs/heads/feat/nuestra)
  refs0=$(git -C "$SB/r" for-each-ref refs/heads | tr -s ' ')
  status0=$(git -C "$SB/r" status --porcelain)
  worktrees0=$(git -C "$SB/r" worktree list | wc -l | tr -d ' ')
}
compara_R() {
  [ "$(git -C "$SB/r" rev-parse HEAD)" = "$head0" ] || fail "HEAD de R cambió"
  [ "$(git -C "$SB/r" rev-parse refs/heads/feat/nuestra)" = "$rama0" ] || fail "la rama de R cambió"
  [ "$(git -C "$SB/r" for-each-ref refs/heads | tr -s ' ')" = "$refs0" ] || fail "las ramas de R cambiaron"
  [ "$(git -C "$SB/r" status --porcelain)" = "$status0" ] || fail "el status de R cambió"
  [ "$(git -C "$SB/r" worktree list | wc -l | tr -d ' ')" = "$worktrees0" ] || fail "R ganó worktrees"
  [ "$(git -C "$SB/r" symbolic-ref HEAD)" = "refs/heads/feat/nuestra" ] || fail "R quedó en otra rama"
}
captura_R

correr() {
  PATH="$SB/bin:$PATH" R_REPO="$SB/r" R_RAMA=feat/nuestra VIGIA_ESTADO="$SB/estado" \
    env "$@" bash "$S" > "$SB/salida" 2>&1
}
linas_ssh() { wc -l < "$SSH_LOG" | tr -d ' '; }

# 1. Al día: sale 0 sin avisar.
correr || { cat "$SB/salida"; fail "la corrida al día falló"; }
grep -q "al día" "$SB/salida" || fail "la corrida al día no lo dijo"
[ ! -s "$SSH_LOG" ] || fail "estando al día avisó igual"
if ls "$SB/estado"/avisado-* >/dev/null 2>&1; then fail "estando al día dejó marca"; fi

# 2. Versión nueva con choques de código y de versión.
correr FAKE_NPM_VERSION=2026.2.3 || { cat "$SB/salida"; fail "la corrida de la versión nueva falló"; }
REPORTE=$(ls "$SB/estado"/*-v2026.2.3.txt 2>/dev/null) || fail "no dejó el reporte v2026.2.3"
grep -q "cambios públicos nuevos: 3" "$REPORTE" || fail "el reporte no cuenta 3 commits nuevos"
grep -q "1 de código, 1 de versión" "$REPORTE" || fail "el reporte no separa código y versión"
grep -qE '^src/gateway\.ts$' "$REPORTE" || fail "el reporte no lista el choque de código"
grep -qE '^src/gateway\.ts$' <(sed -n '/archivos de versión/,$p' "$REPORTE") && fail "gateway.ts quedó clasificado como versión"
grep -q '^CHANGELOG.md$' "$REPORTE" && fail "CHANGELOG.md choca y no debería (solo lo tocó upstream)"
grep -qE '^package\.json$' <(sed -n '/archivos de código/,/archivos de versión/p' "$REPORTE") && fail "package.json quedó clasificado como código"
[ "$(linas_ssh)" = "1" ] || fail "no avisó (o avisó de más) por la versión nueva"
compara_R
MSG="$(tail -1 "$SSH_LOG")"
case "$MSG" in
  *"OpenClaw 2026.2.3 ya salió. claw va en 2026.1.1: 3 cambios públicos, 1 archivos de código chocan con lo nuestro. Conviene actualizar esta semana."*) ;;
  *) fail "el aviso no dice lo que debe: [$MSG]" ;;
esac
case "$MSG" in
  *"--target 6470689715"*) ;;
  *) fail "el aviso no apunta al target de Telegram: [$MSG]" ;;
esac
[ -f "$SB/estado/avisado-v2026.2.3" ] || fail "no dejó la marca de la versión avisada"

# 3. El mismo aviso no se repite.
correr FAKE_NPM_VERSION=2026.2.3 || fail "la segunda corrida de la misma versión falló"
[ "$(linas_ssh)" = "1" ] || fail "repitió el aviso de la misma versión"

# 4. ssh caído: sin marca y salida != 0; reintento con la recomendación de
#    urgencia porque k = 12 > 10. (La rama nuestra gana choques extra aquí:
#    es mutación del test, no del vigía, así que se vuelve a capturar R.)
for i in $(seq 1 11); do printf 'nuestro %s\n' "$i" > "$SB/r/src/extra$i.txt"; done
git -C "$SB/r" add . && git -C "$SB/r" commit -qm "nuestros extras"
captura_R
for i in $(seq 1 11); do printf 'publico %s\n' "$i" > "$W/src/extra$i.txt"; done
git -C "$W" add . && git -C "$W" commit -qm "publicos extras"
git -C "$W" tag v2026.3.9
git -C "$W" push -q "$UP" upstream-trabajo:main v2026.3.9
rc=0
correr FAKE_NPM_VERSION=2026.3.9 FAKE_SSH_RC=7 || rc=$?
[ "$rc" -ne 0 ] || fail "con el ssh caído salió 0"
[ -f "$SB/estado/avisado-v2026.3.9" ] && fail "dejó marca aunque el ssh falló"
[ "$(linas_ssh)" = "2" ] || fail "el ssh caído no lo intentó (o intentó de más)"
correr FAKE_NPM_VERSION=2026.3.9 || { cat "$SB/salida"; fail "el reintento falló"; }
[ "$(linas_ssh)" = "3" ] || fail "el reintento no avisó"
MSG="$(tail -1 "$SSH_LOG")"
case "$MSG" in
  *"4 cambios públicos, 12 archivos de código chocan"*"Ya se juntó bastante: hay que actualizar ya."*) ;;
  *) fail "el reintento no dice lo que debe (conteos o recomendación mal): [$MSG]" ;;
esac
[ -f "$SB/estado/avisado-v2026.3.9" ] || fail "el reintento no dejó la marca"

# Versión v2026.4.0: existe upstream pero aún no se avisó.
printf 'mas\n' > "$W/CHANGELOG.md"
git -C "$W" add . && git -C "$W" commit -qm "publico5"
git -C "$W" tag v2026.4.0
git -C "$W" push -q "$UP" upstream-trabajo:main v2026.4.0

# 5. npm caído: salida != 0 sin aviso ni marca.
rc=0
correr FAKE_NPM_VERSION=2026.9.9 FAKE_NPM_RC=1 || rc=$?
[ "$rc" -ne 0 ] || fail "con npm caído salió 0"
grep -q "npm view falló" "$SB/salida" || fail "con npm caído no nombró el motivo"
[ "$(linas_ssh)" = "3" ] || fail "con npm caído avisó igual"
[ -f "$SB/estado/avisado-v2026.9.9" ] && fail "con npm caído dejó marca"
git -C "$SB/r" rev-parse -q --verify refs/tags/v2026.9.9 >/dev/null 2>&1 \
  && fail "con npm caído igual corrió el fetch del tag"

# 6. npm colgado: el timeout lo mata.
t0=$(date +%s)
rc=0
correr FAKE_NPM_VERSION=2026.9.9 FAKE_NPM_SLEEP=30 VIGIA_TIMEOUT_NPM=2 || rc=$?
[ "$rc" -ne 0 ] || fail "el npm colgado salió 0"
[ $(( $(date +%s) - t0 )) -le 20 ] || fail "el timeout de npm tardó demasiado"
grep -q "npm view falló" "$SB/salida" || fail "el timeout de npm no nombró el motivo"

# 7. VIGIA_SIN_AVISO: hace todo menos el ssh y la marca.
correr VIGIA_SIN_AVISO=1 FAKE_NPM_VERSION=2026.4.0 || { cat "$SB/salida"; fail "la corrida en seco falló"; }
ls "$SB/estado"/*-v2026.4.0.txt >/dev/null 2>&1 || fail "la corrida en seco no dejó reporte"
[ "$(linas_ssh)" = "3" ] || fail "la corrida en seco avisó"
[ -f "$SB/estado/avisado-v2026.4.0" ] && fail "la corrida en seco dejó marca"

# 8. R quedó intacto (desde la última captura: casos 4 a 7).
compara_R
git -C "$SB/r" rev-parse -q --verify refs/tags/v2026.2.3 >/dev/null || fail "el tag v2026.2.3 no llegó"
git -C "$SB/r" rev-parse -q --verify refs/tags/v2026.3.9 >/dev/null || fail "el tag v2026.3.9 no llegó"

# 9. Solo lectura sobre R y plist semanal.
codigo="$(grep -vE '^[[:space:]]*#' "$S")"
printf '%s\n' "$codigo" | grep -nE 'git (checkout|rebase|worktree|merge )' && fail "el vigía escribe en R (checkout/rebase/merge/worktree)"
usados=$(printf '%s\n' "$codigo" | grep -oE 'git -C "\$R" [a-z-]+' | awk '{print $4}' | sort -u | tr '\n' ' ')
[ "$usados" = "fetch merge-tree rev-list rev-parse tag " ] || fail "git sobre R usa algo de más: [$usados]"
printf '%s\n' "$codigo" | grep -E 'fetch origin --no-tags' | grep -q '"tag"' \
  || fail "el fetch no es de un solo tag con --no-tags"
grep -q 'npm view openclaw dist-tags.latest' "$S" || fail "la versión pública no sale del canal latest"
grep -q 'set -euo pipefail' "$S" || fail "el script no corre con set -euo pipefail"
printf '%s\n' "$codigo" | grep -q 'ConnectTimeout=10' || fail "el ssh no trae ConnectTimeout=10"
printf '%s\n' "$codigo" | grep -qF 'IdentitiesOnly=yes -i "$LLAVE"' || fail "el ssh no fija la llave id_gateway"
grep -qE 'beta' <<<"$codigo" && fail "el vigía mira canales beta"
# El comentario de instalación del plist crea ~/bin (y el dir de logs) y usa
# el uid de quien instala, no gui/501 a fuego (G#345 CR 4308463336/3339).
grep -qF 'mkdir -p ~/bin' "$P" || fail "el plist no crea ~/bin antes de copiar el script"
grep -qF 'gui/$(id -u)' "$P" || fail "el plist no usa gui/\$(id -u) en launchctl"
grep -qF 'gui/501' "$P" && fail "el plist trae gui/501 a fuego"
python3 - "$P" <<'E' || fail "plist inválido o no corre lunes 09:00"
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
assert d['Label']=='ai.goncloud.vigia-rebase-r'
pa=d['ProgramArguments']
assert pa[0]=='/bin/bash' and pa[-1].endswith('/vigia-rebase-r.sh')
assert d['StartCalendarInterval']=={'Weekday':1,'Hour':9,'Minute':0}
assert d['EnvironmentVariables']['PATH'].startswith('/opt/homebrew/bin')
assert d['StandardOutPath']==d['StandardErrorPath']=='/Users/dn/Library/Logs/goncloud/vigia-rebase-r.log'
assert not d.get('RunAtLoad', False) and not d.get('KeepAlive')
E

# 10. La marca solo con envío confirmado (G#345 F2): el doble del CLI contesta
#     JSON sin messageId y el vigía no marca y sale != 0; el reintento con
#     messageId confirmado sí marca. Versión v2026.5.1, todavía sin avisar.
git -C "$W" checkout -q upstream-trabajo
printf 'mas mas\n' > "$W/CHANGELOG.md"
git -C "$W" add . && git -C "$W" commit -qm "publico6"
git -C "$W" tag v2026.5.1
git -C "$W" push -q "$UP" upstream-trabajo:main v2026.5.1
rc=0
correr FAKE_NPM_VERSION=2026.5.1 FAKE_SSH_SIN_ID=1 || rc=$?
[ "$rc" -ne 0 ] || fail "el envío sin messageId salió 0"
grep -q "no confirmó messageId" "$SB/salida" || fail "el envío sin messageId no nombró el motivo"
[ -f "$SB/estado/avisado-v2026.5.1" ] && fail "el envío sin messageId dejó marca"
[ "$(linas_ssh)" = "4" ] || fail "el envío sin messageId no llamó al ssh (o llamó de más)"
correr FAKE_NPM_VERSION=2026.5.1 || { cat "$SB/salida"; fail "el reintento con messageId falló"; }
[ "$(linas_ssh)" = "5" ] || fail "el reintento con messageId no avisó (o avisó de más)"
[ -f "$SB/estado/avisado-v2026.5.1" ] || fail "el reintento no dejó la marca con messageId confirmado"

# 11. Fetch roto (tag que no existe en origin): != 0 sin aviso, marca ni
#     reporte, nombrando el motivo (G#345 F1).
rc=0
correr FAKE_NPM_VERSION=2026.9.8 || rc=$?
[ "$rc" -ne 0 ] || fail "con el fetch roto salió 0"
grep -q "no se pudo traer v2026.9.8" "$SB/salida" || fail "con el fetch roto no nombró el motivo"
[ "$(linas_ssh)" = "5" ] || fail "con el fetch roto avisó igual"
[ -f "$SB/estado/avisado-v2026.9.8" ] && fail "con el fetch roto dejó marca"
ls "$SB/estado"/*-v2026.9.8.txt >/dev/null 2>&1 && fail "con el fetch roto dejó reporte"

# 12. merge-tree roto (rc=2 con doble de git): != 0 sin aviso ni marca (G#345
#     F1). Si alguien quita el guard de rc de merge-tree, esta prueba queda
#     roja: la corrida seguiría con la salida basura, contaría "0 choques",
#     avisaría y dejaría marca.
git -C "$W" checkout -q upstream-trabajo
printf 'otra vez\n' > "$W/CHANGELOG.md"
git -C "$W" add . && git -C "$W" commit -qm "publico7"
git -C "$W" tag v2026.6.6
git -C "$W" push -q "$UP" upstream-trabajo:main v2026.6.6
rc=0
correr FAKE_NPM_VERSION=2026.6.6 FAKE_MERGETREE_RC=2 || rc=$?
[ "$rc" -ne 0 ] || fail "con merge-tree roto salió 0"
grep -q "merge-tree falló (rc=2)" "$SB/salida" || fail "con merge-tree roto no nombró el motivo"
[ "$(linas_ssh)" = "5" ] || fail "con merge-tree roto avisó igual"
[ -f "$SB/estado/avisado-v2026.6.6" ] && fail "con merge-tree roto dejó marca"

# 13. Base más nueva que latest (R adelante del canal latest): al día, sin
#     aviso ni marca ni reporte (G#345 F3 / CR 4308463341). El tag v2026.1.0
#     existe en origin (para que el fetch no rompa) pero es más viejo que el
#     v2026.1.1 que ya carga la rama.
git -C "$W" tag v2026.1.0 main
git -C "$W" push -q "$UP" v2026.1.0
correr FAKE_NPM_VERSION=2026.1.0 || { cat "$SB/salida"; fail "la corrida adelantada falló"; }
grep -q "al día (adelantado)" "$SB/salida" || fail "base mayor que latest no lo dijo al día"
[ "$(linas_ssh)" = "5" ] || fail "estando adelantado avisó (o llamó al ssh de más)"
[ -f "$SB/estado/avisado-v2026.1.0" ] && fail "estando adelantado dejó marca"
ls "$SB/estado"/*-v2026.1.0.txt >/dev/null 2>&1 && fail "estando adelantado dejó reporte"

# 14. merge-tree rc=1 sin archivos listados (renombre de directorio): NO es
#     "0 choques" (G#345 CR 4308463348). El reporte y el aviso deben decir
#     conflicto no clasificable, y la corrida avisa y marca normal.
git -C "$W" checkout -q upstream-trabajo
printf 'y otra\n' > "$W/CHANGELOG.md"
git -C "$W" add . && git -C "$W" commit -qm "publico8"
git -C "$W" tag v2026.7.7
git -C "$W" push -q "$UP" upstream-trabajo:main v2026.7.7
correr FAKE_NPM_VERSION=2026.7.7 FAKE_MERGETREE_RC=1 || { cat "$SB/salida"; fail "la corrida de conflicto oscuro falló"; }
REPORTE14=$(ls "$SB/estado"/*-v2026.7.7.txt 2>/dev/null) || fail "la corrida oscura no dejó reporte"
grep -q "conflicto no clasificable" "$REPORTE14" || fail "el reporte oscuro no dice conflicto no clasificable"
grep -q "archivos en conflicto: 0" "$REPORTE14" && fail "el reporte oscuro cuenta 0 choques (implica merge limpio)"
[ "$(linas_ssh)" = "6" ] || fail "la corrida oscura no avisó (o avisó de más)"
case "$(tail -1 "$SSH_LOG")" in
  *"conflicto no clasificable"*) ;;
  *) fail "el aviso oscuro no dice conflicto no clasificable: [$(tail -1 "$SSH_LOG")]" ;;
esac
case "$(tail -1 "$SSH_LOG")" in
  *"0 archivos de código chocan"*) fail "el aviso oscuro implica merge limpio (0 choques)";;
esac
[ -f "$SB/estado/avisado-v2026.7.7" ] || fail "la corrida oscura no dejó marca"

echo "ok: vigía de rebase mide la brecha, avisa una sola vez por versión y deja R intacto"
