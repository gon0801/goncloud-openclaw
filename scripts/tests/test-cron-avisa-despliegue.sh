#!/bin/bash
# Prueba cron-avisa-instala.sh, cron-avisa-checklist.sh y cron-avisa-rollback.sh contra un
# "servidor" de juguete: ssh/scp/crontab/chown/stat falsos y carpetas temporales, con los
# crontabs reales sin secretos de scripts/tests/fixtures/cron-avisa-envuelve/.
# Uso: bash scripts/tests/test-cron-avisa-despliegue.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
G=$PWD/scripts/gonserver
FX=$PWD/scripts/tests/fixtures/cron-avisa-envuelve
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
for f in instala checklist rollback comun; do [ -f "$G/cron-avisa-$f.sh" ] || fail "falta cron-avisa-$f.sh"; done

mkdir -p "$T/bin" "$T/cron" "$T/BIN" "$T/ESTADO" "$T/CROND" "$T/RESP"
cp "$FX/root.crontab" "$T/cron/root"; cp "$FX/gon.crontab" "$T/cron/gon"
cp -R "$FX/cron.d/." "$T/CROND/"

cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
shift
exec bash -c "$*"
SH
cat > "$T/bin/scp" <<'SH'
#!/bin/bash
args=(); for a in "$@"; do [ "$a" = -q ] || args+=("${a#*:}"); done
n=${#args[@]}; dest=${args[$((n-1))]}
cp "${args[@]:0:$((n-1))}" "$dest"
SH
cat > "$T/bin/crontab" <<'SH'
#!/bin/bash
# crontab -l -u U | crontab -u U - | crontab -r -u U
op=$1; [ "$op" = -u ] && { u=$2; op=$3; } || u=$3
echo "crontab $*" >> "$FAKE_LOG"
case $op in
  -l) [ -s "$FAKE_CRON/$u" ] && cat "$FAKE_CRON/$u" || { echo "no crontab for $u" >&2; exit 1; } ;;
  -r) rm -f "$FAKE_CRON/$u" ;;
  -) cat > "$FAKE_CRON/$u" ;;
esac
SH
cat > "$T/bin/chown" <<'SH'
#!/bin/bash
echo "chown $*" >> "$FAKE_LOG"
[ -d "${2:-}" ] && echo "$1" > "$FAKE_OWNER"
exit 0
SH
cat > "$T/bin/stat" <<'SH'
#!/bin/bash
modo=$(python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o7777)[2:])' "$3")
echo "$(cat "$FAKE_OWNER") $modo"
SH
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_CRON="$T/cron" FAKE_LOG="$T/log" FAKE_OWNER="$T/owner"
export CA_BIN="$T/BIN" CA_ESTADO="$T/ESTADO" CA_RESPALDO="$T/RESP" CA_CROND="$T/CROND" CA_LOG="$T/instala.log"
export CRON_AVISA_ESTADO="$T/ESTADO" MOTOR_SHA=prueba
: > "$FAKE_LOG"; echo "desconocido:desconocido" > "$FAKE_OWNER"

correr() { bash "$G/cron-avisa-$1.sh" > "$T/salida-$1" 2>&1; echo $?; }
modo() { python3 -I -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o7777)[2:])' "$1"; }

[ "$(correr checklist)" != 0 ] || fail "el checklist dio 0 sin nada instalado"

[ "$(correr instala)" = 0 ] || { cat "$T/salida-instala"; fail "instala no salió 0"; }
[ "$(modo "$T/BIN/cron-avisa")" = 755 ] || fail "cron-avisa no quedó con 755"
cmp -s "$T/BIN/cron-avisa" "$G/cron-avisa" || fail "el binario instalado no es el del repo"
[ "$(cat "$T/owner")" = root:gon ] || fail "la carpeta de estado no quedó root:gon"
[ "$(modo "$T/ESTADO")" = 2775 ] || fail "la carpeta de estado no quedó 2775"
[ "$(ls "$T/RESP" | wc -l | tr -d ' ')" = 1 ] || fail "debía haber un respaldo"
R=$T/RESP/$(ls "$T/RESP")
cmp -s "$R/crontab-root" "$FX/root.crontab" || fail "el respaldo del crontab de root no es el original"
cmp -s "$R/crontab-gon" "$FX/gon.crontab" || fail "el respaldo del crontab de gon no es el original"
cmp -s "$R/cron.d/goncloud_odoo_backup" "$FX/cron.d/goncloud_odoo_backup" || fail "falta el respaldo de goncloud_odoo_backup"
[ -f "$R/cron.d/php" ] && fail "respaldó un cron.d que no toca (php)"
[ -f "$R/cron.d/ts-watchdog.bak" ] && fail "respaldó un archivo con punto"
grep -q cron-avisa "$T/cron/gon" && ! grep -q spapi_vigilante "$T/cron/root" || fail "los crontabs no quedaron envueltos o root conserva el vigilante"
[ "$(grep -c spapi_vigilante "$T/cron/gon")" = 1 ] || fail "gon debe conservar exactamente una spapi_vigilante"
cmp -s "$T/CROND/php" "$FX/cron.d/php" || fail "tocó /etc/cron.d/php, que no se envuelve"
cmp -s "$T/CROND/ts-watchdog.bak" "$FX/cron.d/ts-watchdog.bak" || fail "tocó un archivo con punto"
grep -q 'cron-avisa --nombre "Respaldo de Odoo"' "$T/CROND/goncloud_odoo_backup" || fail "no envolvió goncloud_odoo_backup"
[ "$(grep -v '^#' "$T/CROND/cron-avisa" | grep -c '^5 9 \* \* \* root /usr/local/bin/cron-avisa --revisa$')" = 1 ] || fail "falta la línea de --revisa en /etc/cron.d/cron-avisa"
ls -A "$T/CROND" | grep -q '^\.cron-avisa\.' && fail "quedó un temporal en /etc/cron.d"
grep -q 'usuario:gon envueltas=34 quitadas=0' "$T/salida-instala" || fail "el log no cuenta las líneas de gon: $(grep usuario "$T/salida-instala")"
grep -q 'usuario:root envueltas=4 quitadas=1' "$T/salida-instala" || fail "el log no cuenta lo de root"
grep -q 'cron.d:php envueltas=0' "$T/salida-instala" || fail "el log no lista los archivos sin cambios"
grep -q 'sha=prueba' "$T/salida-instala" || fail "el log no lleva MOTOR_SHA"
grep -q envueltas "$T/instala.log" || fail "el log del despliegue en el servidor quedó vacío"

[ "$(correr checklist)" = 0 ] || { cat "$T/salida-checklist"; fail "el checklist falló con todo instalado"; }
[ "$(grep -c '^OK:' "$T/salida-checklist")" = 4 ] || fail "el checklist no reporta los cuatro puntos"
cp "$T/cron/gon" "$T/gon.bueno"; cp "$T/cron/root" "$T/root.bueno"
printf '0 5 * * * /mnt/data/appdata/accounting/scripts/audit_postage.py >> /l 2>&1\n' >> "$T/cron/gon"
[ "$(correr checklist)" != 0 ] && grep -q 'sin envolver' "$T/salida-checklist" || fail "el checklist no vio una línea sin envolver"
cp "$T/gon.bueno" "$T/cron/gon"
printf '30 7 * * * /usr/bin/flock -n /tmp/spapi-vigilante.lock docker exec orbit-app-1 python -m app.cli spapi_vigilante >> /l 2>&1\n' >> "$T/cron/root"
[ "$(correr checklist)" != 0 ] || fail "el checklist no vio el duplicado de spapi_vigilante en root"
cp "$T/root.bueno" "$T/cron/root"
chmod 755 "$T/ESTADO"
[ "$(correr checklist)" != 0 ] && grep -q 'debía ser' "$T/salida-checklist" || fail "el checklist no vio el modo de la carpeta de estado"
chmod 2775 "$T/ESTADO"
echo "x:y" > "$T/owner"
[ "$(correr checklist)" != 0 ] || fail "el checklist no vio el dueño de la carpeta de estado"
echo root:gon > "$T/owner"
echo '{"nombre":"Tarea vieja","fin":1,"cada":1}' > "$T/ESTADO/vieja.json"
[ "$(correr checklist)" = 0 ] || fail "--revisa saliendo 1 debe aceptarse"
echo 'no es json' > "$T/ESTADO/rota.json"
[ "$(correr checklist)" != 0 ] || fail "--revisa saliendo 2 debe rechazarse"
rm -f "$T/ESTADO"/*.json
mv "$T/BIN/cron-avisa" "$T/BIN/cron-avisa.x"
[ "$(correr checklist)" != 0 ] || fail "el checklist no vio que falta el binario"
mv "$T/BIN/cron-avisa.x" "$T/BIN/cron-avisa"
[ "$(correr checklist)" = 0 ] || fail "el checklist no se recuperó"

[ "$(correr instala)" = 0 ] || fail "la segunda instalación falló"
[ "$(ls "$T/RESP" | wc -l | tr -d ' ')" = 1 ] || fail "la segunda instalación creó otro respaldo"
cmp -s "$T/cron/gon" "$T/gon.bueno" || fail "la segunda instalación cambió el crontab de gon"
grep -q 'nada que cambiar' "$T/salida-instala" || fail "la segunda instalación no dijo que no había nada"

grep -v spapi_vigilante "$T/gon.bueno" > "$T/cron/gon"
printf '30 7 * * * /usr/bin/flock -n /tmp/spapi-vigilante.lock docker exec orbit-app-1 python -m app.cli spapi_vigilante >> /l 2>&1\n' >> "$T/cron/root"
cp "$T/cron/root" "$T/root.malo"
[ "$(correr instala)" != 0 ] && grep -q 'no quito la única copia' "$T/salida-instala" || fail "debía negarse a quitar la única vigilante"
cmp -s "$T/cron/root" "$T/root.malo" || fail "quitó la única vigilante"
cp "$T/gon.bueno" "$T/cron/gon"; cp "$T/root.bueno" "$T/cron/root"

printf '0 5 * * * /x/algo_nuevo.sh >> /l 2>&1\n' >> "$T/cron/gon"; cp "$T/cron/gon" "$T/gon.malo"
[ "$(correr instala)" != 0 ] || fail "una línea sin frase no detuvo la instalación"
cmp -s "$T/cron/gon" "$T/gon.malo" || fail "escribió pese a la línea sin frase"
cp "$T/gon.bueno" "$T/cron/gon"

[ "$(correr rollback)" = 0 ] || { cat "$T/salida-rollback"; fail "el rollback no salió 0"; }
cmp -s "$T/cron/root" "$FX/root.crontab" || fail "el rollback no restauró el crontab de root"
cmp -s "$T/cron/gon" "$FX/gon.crontab" || fail "el rollback no restauró el crontab de gon"
cmp -s "$T/CROND/goncloud_odoo_backup" "$FX/cron.d/goncloud_odoo_backup" || fail "el rollback no restauró goncloud_odoo_backup"
[ -e "$T/CROND/cron-avisa" ] && fail "el rollback no quitó /etc/cron.d/cron-avisa"
[ -x "$T/BIN/cron-avisa" ] || fail "el rollback no debe tocar el binario"
rm -rf "$T/RESP"; mkdir "$T/RESP"
[ "$(correr rollback)" != 0 ] || fail "el rollback sin respaldo debe fallar"

grep -qE 'crontab -u (root|gon) -' "$FAKE_LOG" || fail "nunca escribió con crontab -u <usuario> -"
echo "OK: test-cron-avisa-despliegue"
