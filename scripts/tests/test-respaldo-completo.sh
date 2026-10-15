#!/bin/bash
# Respaldo completo de la Mini (scripts/mac/respaldo-completo.sh), sin red: un openclaw
# de mentira y un ssh de mentira que corre el receptor real (scripts/gonserver/
# recibe-respaldo) con el nombre como SSH_ORIGINAL_COMMAND, como el command= forzado.
#
#   1. Corrida buena: backup y extras llegan al servidor con el sha256 local, sin aviso;
#      el backup se crea con --verify; ssh va con la llave, IdentitiesOnly y BatchMode.
#   2. Extras: los plists ai.openclaw.* y ai.goncloud.* sí, otros no; sin sockets; lo que
#      falta queda anotado en el log y en RESPALDO-EXTRAS.txt; incluye este script.
#   3. En la Mac quedan los 2 más nuevos de cada tipo.
#   4. Una subida que falla se reintenta alternando servidores y a la tercera va.
#   5. Sin más intentos: sale 1, avisa una vez por `openclaw message send` con la causa de
#      los dos archivos, y deja los archivos locales.
#   6. Un sha256 que no coincide es una falla.
#   7. Si `backup create` falla o no verifica, los extras igual se suben y avisa.
#   8. Lock vivo: sale 3 sin aviso; lock huérfano: se recupera.
#   9. Una subida muda no retiene la corrida: cada intento tiene tope.
#  10. El plist, con la plantilla llena, es válido: 03:30, PATH con node, apunta al script.
#  11. Un extra que tar no puede leer: dos intentos, falla y avisa; el backup igual sube.
#
# Corre el script con /bin/bash: en macOS es el 3.2 de la Mini.
# Uso: bash scripts/tests/test-respaldo-completo.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
REPO="$PWD"
S="$REPO/scripts/mac/respaldo-completo.sh"
P="$REPO/scripts/mac/ai.goncloud.respaldo-completo.plist"
RECEPTOR="$REPO/scripts/gonserver/recibe-respaldo"
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
F=20261015

# HOME de juguete con lo que la Mini tiene fuera de ~/.openclaw (falta .openclaw-state).
H="$SB/home"
mkdir -p "$H/Library/LaunchAgents" "$H/goncloud-autoupdate" "$H/.claude" "$H/.ssh" "$H/.local/bin"
for f in ai.openclaw.gateway.plist ai.goncloud.respaldo-completo.plist com.apple.otro.plist; do
  printf '<plist/>\n' > "$H/Library/LaunchAgents/$f"
done
printf 'auto\n' > "$H/goncloud-autoupdate/actualizar.sh"
printf '{}\n' > "$H/.claude/settings.json"; printf '{}\n' > "$H/.claude.json"
printf 'llave\n' > "$H/.ssh/claw_goncloud"; printf 'export X=1\n' > "$H/.zshrc"
printf 'bin\n' > "$H/.local/bin/herramienta"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$H/.ssh/s" \
  || fail "no se pudo crear el socket de prueba"

# openclaw de mentira: `backup create` deja un .tar.gz real en --output; `message send`
# anota el aviso. FAKE_OC: falla | sin-verificar.
cat > "$SB/openclaw" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$SB/oc-llamadas"
case "\$1 \$2" in
  "backup create")
    out=""; prev=""
    for a in "\$@"; do [ "\$prev" = --output ] && out="\$a"; prev="\$a"; done
    case "\${FAKE_OC:-}" in falla) echo "Error: disco lleno" >&2; exit 1 ;; esac
    mkdir -p "$SB/estado/.openclaw"; echo "estado \$\$" > "$SB/estado/.openclaw/openclaw.json"
    a="\$out/2026-10-15T03-30-00.000Z-openclaw-backup.tar.gz"
    tar -czf "\$a" -C "$SB/estado" .openclaw
    v=true; [ "\${FAKE_OC:-}" = sin-verificar ] && v=false
    printf '{\n  "archivePath": "%s",\n  "verified": %s\n}\n' "\$a" "\$v" ;;
  "message send")
    m=""; prev=""; for a in "\$@"; do [ "\$prev" = -m ] && m="\$a"; prev="\$a"; done
    printf '%s\n' "\$m" >> "$SB/avisos" ;;
esac
EOS
chmod +x "$SB/openclaw"

# ssh de mentira: anota argumentos, corre el receptor real. FAKE_SSH_FALLAS = cuántas
# llamadas fallan primero; FAKE_SSH=sha-malo | mudo.
cat > "$SB/ssh" <<EOS
#!/bin/sh
n=\$(cat "$SB/ssh-n" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$SB/ssh-n"
printf '%s\n' "\$*" >> "$SB/ssh-llamadas"
for a in "\$@"; do host="\$nombre"; nombre="\$a"; done
if [ "\$n" -le "\${FAKE_SSH_FALLAS:-0}" ]; then cat > /dev/null; echo "ssh: connect to host \${host#*@}: Network is unreachable" >&2; exit 255; fi
case "\${FAKE_SSH:-}" in
  mudo) exec sleep 30 ;;
  sha-malo) cat > /dev/null; echo 0000; exit 0 ;;
esac
SSH_ORIGINAL_COMMAND="\$nombre" RECIBE_BASE="$SB/servidor" sh "$RECEPTOR" openclaw
EOS
chmod +x "$SB/ssh"

correr() { # variables extra como argumentos de env
  rm -f "$SB/ssh-n"
  env HOME="$H" RC_DIR="$SB/local" RC_LOG="$SB/log" RC_FECHA="$F" OPENCLAW_BIN="$SB/openclaw" \
    RC_SSH="$SB/ssh" RC_ESPERA=0 RC_LLAVE="$H/.ssh/claw_goncloud" "$@" /bin/bash "$S"
}
avisos() { [ -f "$SB/avisos" ] && wc -l < "$SB/avisos" | tr -d ' ' || echo 0; }
L="$SB/local"; SV="$SB/servidor/openclaw"

# 1
correr; rc=$?
[ "$rc" -eq 0 ] || { cat "$SB/log"; fail "la corrida buena salió $rc"; }
for t in backup extras; do
  [ -f "$L/openclaw-$t-$F.tar.gz" ] || fail "no quedó openclaw-$t-$F.tar.gz en la Mac"
  [ "$(sha "$SV/openclaw-$t-$F.tar.gz" 2>/dev/null)" = "$(sha "$L/openclaw-$t-$F.tar.gz")" ] \
    || fail "openclaw-$t-$F.tar.gz no llegó igual al servidor"
done
tar -tzf "$L/openclaw-backup-$F.tar.gz" | grep -q '^\.openclaw/openclaw.json$' || fail "el backup no es el que creó openclaw"
[ "$(avisos)" = 0 ] || fail "una corrida buena avisó"
grep -q -- "^backup create --output $L/.tmp.[^ ]*/crear --verify --json$" "$SB/oc-llamadas" \
  || fail "backup create no se llamó como se espera: $(cat "$SB/oc-llamadas")"
[ "$(head -1 "$SB/ssh-llamadas")" = "-i $H/.ssh/claw_goncloud -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 clawbackup@10.13.13.1 openclaw-backup-$F.tar.gz" ] \
  || fail "ssh no se llamó como se espera: $(head -1 "$SB/ssh-llamadas")"
grep -q "terminado sin fallas" "$SB/log" || fail "el log no cierra la corrida buena"
ls -A "$L" | grep -q '^\.' && fail "quedó el lock o un temporal: $(ls -A "$L" | tr '\n' ' ')"

# 2
tar -tzf "$L/openclaw-extras-$F.tar.gz" > "$SB/extras.txt"
for r in Library/LaunchAgents/ai.openclaw.gateway.plist Library/LaunchAgents/ai.goncloud.respaldo-completo.plist \
         goncloud-autoupdate/actualizar.sh .claude/settings.json .claude.json .ssh/claw_goncloud .zshrc \
         .local/bin/herramienta; do
  grep -q "home/$r\$" "$SB/extras.txt" || fail "los extras no traen ~/$r"
done
grep -q "com.apple.otro.plist" "$SB/extras.txt" && fail "los extras traen un plist ajeno"
grep -q "\.ssh/s\$" "$SB/extras.txt" && fail "los extras traen un socket"
grep -qx "${S#/}" "$SB/extras.txt" || fail "los extras no traen el script instalado"
grep -qx "${L#/}/RESPALDO-EXTRAS.txt" "$SB/extras.txt" || fail "los extras no traen su nota"
tar -xzOf "$L/openclaw-extras-$F.tar.gz" "${L#/}/RESPALDO-EXTRAS.txt" | grep -qx "omitido (no existe): ~/.openclaw-state" \
  || fail "la nota no dice qué faltó"
grep -q "extras: omitido (no existe): ~/.openclaw-state" "$SB/log" || fail "el log no dice qué faltó"

# 3
for d in 20261011 20261012 20261013; do
  for t in backup extras; do printf 'viejo\n' > "$L/openclaw-$t-$d.tar.gz"; done
done
correr || fail "la corrida con archivos viejos falló"
[ "$(cd "$L" && ls openclaw-* | tr '\n' ' ')" = "openclaw-backup-20261013.tar.gz openclaw-backup-$F.tar.gz openclaw-extras-20261013.tar.gz openclaw-extras-$F.tar.gz " ] \
  || fail "no quedaron los 2 más nuevos de cada tipo: $(ls "$L" | tr '\n' ' ')"

# 4
: > "$SB/ssh-llamadas"
correr FAKE_SSH_FALLAS=2 || { cat "$SB/log"; fail "no reintentó la subida"; }
[ "$(awk '{ print $(NF-1) }' "$SB/ssh-llamadas" | tr '\n' ' ')" = "clawbackup@10.13.13.1 clawbackup@100.127.167.103 clawbackup@10.13.13.1 clawbackup@10.13.13.1 " ] \
  || fail "los intentos no alternaron servidores: $(awk '{ print $(NF-1) }' "$SB/ssh-llamadas" | tr '\n' ' ')"
grep -q "openclaw-backup-$F.tar.gz: intento 2 a 100.127.167.103 falló (ssh: connect to host 100.127.167.103: Network is unreachable" "$SB/log" \
  || fail "el log no nombra el intento que falló"
[ "$(avisos)" = 0 ] || fail "un reintento que terminó bien avisó"

# 5
rm -rf "$SB/servidor"
correr FAKE_SSH_FALLAS=99; rc=$?
[ "$rc" -eq 1 ] || fail "sin subir nada no salió 1 (rc=$rc)"
[ "$(avisos)" = 1 ] || fail "esperaba exactamente un aviso, hubo $(avisos)"
[ "$(cat "$SB/avisos")" = "El respaldo completo de la Mac mini a gonserver falló: openclaw-backup-$F.tar.gz no se subió tras 3 intento(s): ssh: connect to host 10.13.13.1: Network is unreachable; openclaw-extras-$F.tar.gz no se subió tras 3 intento(s): ssh: connect to host 10.13.13.1: Network is unreachable. Revisa $SB/log." ] \
  || fail "el aviso no trae las dos causas: $(cat "$SB/avisos")"
grep -q -- "message send --channel telegram -t 6470689715 -m El respaldo completo" "$SB/oc-llamadas" \
  || fail "el aviso no salió por Telegram al chat de David"
[ -f "$L/openclaw-backup-$F.tar.gz" ] && [ -f "$L/openclaw-extras-$F.tar.gz" ] || fail "una subida fallida borró el archivo local"
[ -e "$L/.lock" ] && fail "el lock quedó tomado tras fallar"
rm -f "$SB/avisos"

# 6
correr FAKE_SSH=sha-malo RC_INTENTOS=2; rc=$?
[ "$rc" -eq 1 ] || fail "un sha256 distinto no hizo fallar la corrida (rc=$rc)"
grep -q "openclaw-backup-$F.tar.gz no se subió tras 2 intento(s): el sha256 no coincide (servidor: 0000)" "$SB/log" \
  || fail "el log no dice que el sha256 no coincide"
rm -f "$SB/avisos"

# 7
for modo in falla sin-verificar; do
  rm -rf "$SB/servidor" "$L"
  correr FAKE_OC=$modo; rc=$?
  [ "$rc" -eq 1 ] || fail "backup create en modo $modo no hizo fallar la corrida (rc=$rc)"
  [ -f "$SV/openclaw-extras-$F.tar.gz" ] || fail "con backup create en modo $modo los extras no se subieron"
  [ -e "$SV/openclaw-backup-$F.tar.gz" ] && fail "con backup create en modo $modo igual se subió un backup"
  [ "$(avisos)" = 1 ] || fail "backup create en modo $modo no avisó exactamente una vez"
  rm -f "$SB/avisos"
done
grep -q "FALLA: openclaw backup create falló: Error: disco lleno" "$SB/log" || fail "el log no trae la causa de backup create"
grep -q "FALLA: openclaw backup create no verificó el archivo" "$SB/log" || fail "el log no dice que no verificó"

# 8
yo="$$ $(ps -o lstart= -p $$ | tr -s ' ')"
mkdir -p "$L/.lock"; printf '%s' "$yo" > "$L/.lock/dueno"
correr; rc=$?
[ "$rc" -eq 3 ] || fail "con el lock de un proceso vivo no salió 3 (rc=$rc)"
[ "$(cat "$L/.lock/dueno")" = "$yo" ] || fail "se robó el lock de un proceso vivo"
[ "$(avisos)" = 0 ] || fail "el lock de otra corrida avisó"
echo "999999 Thu 1 Jan 00:00:00 1970" > "$L/.lock/dueno"
correr || { cat "$SB/log"; fail "un lock huérfano detuvo el respaldo"; }
grep -q "lock huérfano" "$SB/log" || fail "no reportó el lock huérfano"

# 9
t0=$(date +%s)
correr FAKE_SSH=mudo RC_TOPE=1 RC_INTENTOS=2; rc=$?
[ "$rc" -eq 1 ] || fail "una subida muda no salió 1 (rc=$rc)"
[ $(( $(date +%s) - t0 )) -lt 20 ] || fail "una subida muda retuvo la corrida más de 20 s"
grep -q "openclaw-extras-$F.tar.gz no se subió tras 2 intento(s): sin respuesta en 1s" "$SB/log" \
  || fail "el log no dice que la subida quedó muda"

# 11
rm -rf "$SB/servidor" "$L"; rm -f "$SB/avisos"
printf 'secreto\n' > "$H/.claude/ilegible"; chmod 000 "$H/.claude/ilegible"
correr; rc=$?
chmod 600 "$H/.claude/ilegible"; rm -f "$H/.claude/ilegible"
[ "$rc" -eq 1 ] || fail "un extra ilegible no hizo fallar la corrida (rc=$rc)"
[ "$(grep -c "extras: tar falló en el intento" "$SB/log")" = 2 ] || fail "no reintentó armar los extras"
grep -q "FALLA: no se pudo armar los extras: .*ilegible" "$SB/log" || fail "el log no nombra el extra ilegible"
[ -e "$SV/openclaw-extras-$F.tar.gz" ] && fail "se subieron extras incompletos"
[ -f "$SV/openclaw-backup-$F.tar.gz" ] || fail "con los extras rotos el backup no se subió"
[ "$(avisos)" = 1 ] || fail "los extras rotos no avisaron exactamente una vez"

# 10
sed -e "s|__HOME__|/Users/gon|g" -e "s|__NODE_BIN__|/Users/gon/.openclaw/tools/node-v24.19.0/bin|g" "$P" > "$SB/p.plist"
grep -q '__' "$SB/p.plist" && fail "la plantilla tiene un marcador que la instalación no llena"
python3 - "$SB/p.plist" <<'E' || fail "plist inválido o con otro horario, PATH o script"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == "ai.goncloud.respaldo-completo"
assert d["ProgramArguments"] == ["/bin/bash", "/Users/gon/bin/respaldo-completo.sh"], d["ProgramArguments"]
assert d["StartCalendarInterval"] == {"Hour": 3, "Minute": 30}
assert d["EnvironmentVariables"]["PATH"].split(":")[0] == "/Users/gon/.openclaw/tools/node-v24.19.0/bin"
assert d["StandardOutPath"] == "/Users/gon/Library/Logs/goncloud/respaldo-completo.log"
assert not d.get("KeepAlive") and not d.get("RunAtLoad")
E

echo "ok: respaldo completo verificado, subido con sha256, reintentos, retención local y aviso solo al fallar"
