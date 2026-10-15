# Respaldo completo y reinstalación de la Mac mini del gateway

Este runbook cubre el respaldo diario de la Mac mini donde corre el gateway de OpenClaw (usuario `gon`, Tailscale `100.73.187.5`, WireGuard `10.13.13.6`) y cómo levantar todo en una Mac nueva a partir de ese respaldo. El respaldo de la PC de Hermes es otro procedimiento; ver [Hermes](#hermes) al final.

## Qué se respalda, dónde y cada cuánto

`scripts/mac/respaldo-completo.sh` corre en la Mini todos los días a las 03:30 (LaunchAgent `ai.goncloud.respaldo-completo`). Produce dos archivos y los sube a gonserver:

| Archivo | Contenido | En gonserver | En la Mini |
|---|---|---|---|
| `openclaw-backup-AAAAMMDD.tar.gz` | `openclaw backup create --verify`: todo `~/.openclaw` (configuración, `state/openclaw.sqlite`, agentes, `credentials/`, `.env`, perfil del navegador `browser/claw`) | `/mnt/data/backups/openclaw/`, los 7 más nuevos | `~/respaldo-completo/`, los 2 más nuevos |
| `openclaw-extras-AAAAMMDD.tar.gz` | Lo que vive fuera de `~/.openclaw`. Requeridos: `~/Library/LaunchAgents/ai.openclaw.*.plist` (al menos uno), `~/goncloud-autoupdate/`, `~/.ssh/`, `~/.zshrc` y el script instalado. Opcionales: `~/Library/LaunchAgents/ai.goncloud.*.plist`, `~/.claude/`, `~/.claude.json`, `~/.openclaw-state/` y `~/.local/bin/` | igual | igual |

Dentro del archivo de extras, `Users/gon/respaldo-completo/RESPALDO-EXTRAS.txt` trae la salida de `openclaw --version` y `node --version` de ese día, y lo que faltaba. Si falta un requerido, la corrida falla y avisa, pero igual sube lo que hay. Si falta un opcional, solo queda anotado (`~/.openclaw-state/` no existía en la Mini el 2026-10-15).

Lo que **no** está en el respaldo y hay que rehacer a mano:

- El llavero de macOS. Ahí viven el inicio de sesión del CLI `claude` y la llave con la que Chrome cifra las cookies, así que las sesiones del perfil `claw` del navegador (Seller Central .com y .com.mx, Flex, Gmail) no sobreviven a una Mac nueva.
- Los `node_modules` de los plugins y los enlaces de skills generados. OpenClaw los avisa al restaurar.
- Las credenciales de canales con estado de ratchet (WhatsApp) pueden pedir volver a vincular.

Cada subida tiene 3 intentos de hasta 30 minutos, alternando WireGuard (`10.13.13.1`) y Tailscale (`100.127.167.103`). El receptor contesta el sha256 de lo que guardó y el script lo compara con el local. Si algo falla, el script avisa por Telegram a David (`openclaw message send`). Si todo sale bien, no avisa. El detalle queda en `~/Library/Logs/goncloud/respaldo-completo.log`. Si la corrida recibe SIGTERM (bootout de launchd o apagado de la Mac), borra su temporal y avisa. Si muere sin limpiar, la corrida siguiente borra los `~/respaldo-completo/.tmp.*` que queden.

El receptor rechaza un nombre cuya fecha no cae entre hoy-60 y hoy+1 según el reloj de gonserver (sale 2), y una subida de más de 20 GiB (sale 4). En los dos casos no escribe nada.

En gonserver, `vigila-respaldos` revisa todos los días a las 09:00 que `openclaw-backup`, `openclaw-extras` y `hermes-backup` tengan un archivo de menos de 36 h que pese al menos la mitad del anterior. Si no, avisa por Telegram con el bot de Orbit. Las 09:00 son de la zona horaria de gonserver (`timedatectl | grep 'Time zone'`), no de la Mini.

Nadie vigila al vigía. Si hay un problema y el archivo de claves falta o Telegram rechaza el envío, el aviso no sale. El vigía sale con 2 y el error solo queda en `/var/log/vigila-respaldos.log`. Para revisarlo, como root en gonserver:

```sh
tail -20 /var/log/vigila-respaldos.log              # vacío si todo estuvo al día; "ERROR: no se pudo avisar" si el aviso falló
journalctl --since today | grep vigila-respaldos     # que cron lo haya lanzado a las 09:00
/usr/local/bin/vigila-respaldos; echo "salida $?"    # 0 al día, 1 había problemas y avisó, 2 había problemas y no pudo avisar
```

La corrida a mano manda el aviso de Telegram si encuentra problemas.

## Instalar el receptor en gonserver

Se hace una vez, como root en gonserver, desde una copia de este repo. La cuenta `clawbackup` (home `/var/lib/clawbackup`) ya existe.

1. Copia los dos scripts:

   ```sh
   scp scripts/gonserver/recibe-respaldo scripts/gonserver/vigila-respaldos gonserver:/tmp/
   ssh gonserver 'install -m 755 -o root -g root /tmp/recibe-respaldo /tmp/vigila-respaldos /usr/local/bin/ &&
     install -d -o clawbackup -g clawbackup -m 700 /mnt/data/backups/openclaw /mnt/data/backups/hermes'
   ```

2. En `/var/lib/clawbackup/.ssh/authorized_keys` deja estas dos líneas. La primera es la llave que la Mini ya usa para la cuenta `claw` (`~/.ssh/claw_goncloud.pub` en la Mini, comentario `claw@OPENCLAW-goncloud`). La segunda reemplaza el `command=` de la línea de Hermes que ya existe:

   ```text
   restrict,from="100.73.187.5,10.13.13.6",command="/usr/local/bin/recibe-respaldo openclaw" ssh-ed25519 <clave de claw_goncloud.pub> claw@OPENCLAW-goncloud
   restrict,command="/usr/local/bin/recibe-respaldo hermes" ssh-ed25519 <clave existente> claw-backup@Gon
   ```

   La familia `hermes` sigue aceptando el nombre viejo `claw-backup-AAAAMMDD.tar.gz` en `/mnt/data/backups/claw/` (guarda 8). Por eso el script actual de la PC sigue funcionando aunque cambie la línea. Deja `/usr/local/bin/recibe-claw-backup` hasta que nada lo use.

3. Programa el vigía en el cron de root:

   ```sh
   ssh gonserver "printf '0 9 * * * root /usr/local/bin/vigila-respaldos >> /var/log/vigila-respaldos.log 2>&1\n' > /etc/cron.d/vigila-respaldos"
   ```

   El vigía lee el token y el chat del bot de `/mnt/data/appdata/orbit/secrets/accounting.env` y nunca los imprime.

4. Deja en `~/.ssh/known_hosts` de la Mini la llave de gonserver para sus dos direcciones, `10.13.13.1` y `100.127.167.103`. El script usa `StrictHostKeyChecking=yes`, así que con una dirección que no está en `known_hosts` la subida falla. El 2026-10-15 la Mini conocía `100.127.167.103` pero no `10.13.13.1`. Primero lee la huella verdadera en gonserver, desde la MacBook:

   ```sh
   ssh gonserver 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub'
   ```

   En la Mini, pide la llave que contesta `10.13.13.1` y mira su huella:

   ```sh
   ssh-keyscan -t ed25519 10.13.13.1 2>/dev/null > /tmp/gonserver-wg.pub
   ssh-keygen -lf /tmp/gonserver-wg.pub
   ```

   Si las dos huellas `SHA256:...` no son iguales, no la agregues: otra máquina contesta en esa dirección y hay que averiguar cuál. Si son iguales, agrégala y revisa las dos direcciones:

   ```sh
   cat /tmp/gonserver-wg.pub >> ~/.ssh/known_hosts
   ssh-keygen -lF 10.13.13.1
   ssh-keygen -lF 100.127.167.103
   ```

   Cada una tiene que mostrar al menos una huella. Si una muestra una línea `ED25519`, su huella tiene que ser la de gonserver.

5. Comprueba el receptor desde la Mini con un archivo de prueba con la fecha de hoy. El receptor rechaza fechas viejas, y un nombre viejo como `20000101` quedaría fuera de los 7 más nuevos. Antes, desde la MacBook, comprueba que todavía no hay extras de hoy, porque la prueba los reemplazaría. Usa la misma fecha que imprime `date +%Y%m%d` en la Mini:

   ```sh
   F=AAAAMMDD
   ssh gonserver "test ! -e /mnt/data/backups/openclaw/openclaw-extras-$F.tar.gz" && echo "se puede probar"
   ```

   En la Mini. El segundo comando tiene que imprimir el mismo sha256 que el primero:

   ```sh
   F=$(date +%Y%m%d); cd "$(mktemp -d)" && echo prueba > p && tar -czf openclaw-extras-$F.tar.gz p
   shasum -a 256 openclaw-extras-$F.tar.gz
   ssh -i ~/.ssh/claw_goncloud -o IdentitiesOnly=yes -o BatchMode=yes clawbackup@10.13.13.1 openclaw-extras-$F.tar.gz < openclaw-extras-$F.tar.gz
   ```

   Después borra la prueba, desde la MacBook, con la misma `F`:

   ```sh
   ssh gonserver "rm /mnt/data/backups/openclaw/openclaw-extras-$F.tar.gz"
   ```

## Instalar el respaldo en la Mini

Antes haz los pasos 4 y 5 de la sección anterior. Sin la llave de `10.13.13.1` en `known_hosts`, la primera subida falla.

Como `gon`, desde una copia de este repo:

```sh
NODE_BIN="$(dirname "$(ls -d ~/.openclaw/tools/node-v*/bin/node | tail -1)")"
mkdir -p ~/bin ~/Library/Logs/goncloud
cp scripts/mac/respaldo-completo.sh ~/bin/
sed -e "s|__HOME__|$HOME|g" -e "s|__NODE_BIN__|$NODE_BIN|g" \
  scripts/mac/ai.goncloud.respaldo-completo.plist > ~/Library/LaunchAgents/ai.goncloud.respaldo-completo.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.goncloud.respaldo-completo.plist
launchctl kickstart gui/$(id -u)/ai.goncloud.respaldo-completo
```

La corrida tarda unos 12 minutos: unos 2,5 minutos para `backup create` (medido el 2026-10-15: 143 s, 3,9 GB) y unos 8 minutos de subida a ~63 Mbps. Termina bien cuando la última línea del log dice `terminado sin fallas` y gonserver tiene los dos archivos del día:

```sh
tail -5 ~/Library/Logs/goncloud/respaldo-completo.log
ssh gonserver 'ls -l /mnt/data/backups/openclaw/'
```

## Reinstalar en una Mac nueva

Antes de empezar:

- Crea el usuario `gon` en la Mac nueva. La configuración de OpenClaw, los LaunchAgents y las llaves de las automatizaciones (`cron_jobs.store_key`) guardan rutas `/Users/gon/...`. Con otro usuario hay que reescribir esas rutas, como en la mudanza del 2026-10-09 desde Windows.
- Conecta la Mac a Tailscale y a WireGuard. Si sus IPs no son `100.73.187.5` y `10.13.13.6`, cambia el `from=` de la llave `claw_goncloud` en gonserver, tanto en `~claw` como en `~clawbackup`. Si no lo cambias, el respaldo de la Mac nueva no podrá subir.
- Si la Mini vieja sigue encendida, detén su gateway (`launchctl bootout gui/501/ai.openclaw.gateway`). Dos gateways con el mismo bot de Telegram se pelean los mensajes.

### 1. Traer los archivos

Desde la MacBook, que entra a gonserver como root con `ssh gonserver`:

```sh
ssh gonserver 'ls -l /mnt/data/backups/openclaw/'
```

Elige el día más reciente que tenga los dos archivos y sustituye `AAAAMMDD` por esa fecha:

```sh
F=AAAAMMDD
ssh gonserver "cd /mnt/data/backups/openclaw && sha256sum openclaw-backup-$F.tar.gz openclaw-extras-$F.tar.gz"
mkdir -p ~/restauracion && cd ~/restauracion
scp "gonserver:/mnt/data/backups/openclaw/openclaw-*-$F.tar.gz" .
```

Pasa los dos archivos a `~/restauracion/` en la Mac nueva (`scp`, AirDrop o un disco). Ahí, comprueba que el sha256 coincide con el que imprimió gonserver:

```sh
cd ~/restauracion
F=AAAAMMDD; B=openclaw-backup-$F.tar.gz; E=openclaw-extras-$F.tar.gz
shasum -a 256 "$B" "$E"
```

### 2. Instalar OpenClaw en la versión del respaldo

La nota del archivo de extras dice con qué versión de OpenClaw y de node se hizo el respaldo:

```sh
tar -xzOf "$E" Users/gon/respaldo-completo/RESPALDO-EXTRAS.txt | sed -n '2,3p'
```

Imprime dos líneas como `openclaw: OpenClaw 2026.9.7 (f8316c9)` y `node: v24.19.0 (/Users/gon/.openclaw/tools/node-v24.19.0/bin/node)`. Los respaldos anteriores a que el script anotara las versiones no traen esas líneas. En ese caso instala cualquier versión, haz el paso 3 hasta `backup restore`, lee la versión en su `runtimeVersion` y vuelve a este paso.

Instala esa misma versión en `~/.openclaw`, como estaba en la Mini. Sustituye `<versión de openclaw>` y `<versión de node sin la v>` por los valores de la nota, en el ejemplo `2026.9.7` y `24.19.0`. No uses `--onboard`, porque crearía un estado nuevo encima del que vas a restaurar:

```sh
curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh \
  | bash -s -- --prefix "$HOME/.openclaw" --version <versión de openclaw> --node-version <versión de node sin la v>
~/.openclaw/bin/openclaw --version
```

### 3. Restaurar el estado de OpenClaw

`openclaw backup restore` verifica el archivo y lo extrae en un directorio nuevo. Nunca escribe sobre `~/.openclaw`. El destino tiene que estar vacío, así que si repites el paso, el `rm -rf` borra la extracción anterior:

```sh
rm -rf ~/restauracion/estado
~/.openclaw/bin/openclaw backup restore ~/restauracion/"$B" --target ~/restauracion/estado --json > ~/restauracion/restore.json
grep -E '"(ok|runtimeVersion)"' ~/restauracion/restore.json
RAIZ="$(tar -tzf ~/restauracion/"$B" | head -1 | cut -d/ -f1)"
P=~/restauracion/estado/"$RAIZ"/payload/posix/Users/gon/.openclaw
ls "$P/openclaw.json" "$P/state/openclaw.sqlite"
```

El `grep` tiene que mostrar `"ok": true` y un `runtimeVersion` igual a la versión que instalaste en el paso 2. Así lo reportó el restore de prueba del 2026-10-15 (`runtimeVersion: "2026.9.7"`).

Comprueba que el gateway no está corriendo. Este comando tiene que fallar con `Could not find service`:

```sh
launchctl print gui/$(id -u)/ai.openclaw.gateway
```

Si en cambio imprime el servicio, el instalador dejó un gateway cargado. Descárgalo y vuelve a correr el `launchctl print`:

```sh
launchctl bootout gui/$(id -u)/ai.openclaw.gateway
```

Copia el estado a su lugar. Se excluyen `bin/` y `tools/` para conservar el OpenClaw y el node que acabas de instalar:

```sh
rsync -a --exclude /bin/ --exclude /tools/ "$P/" ~/.openclaw/
sqlite3 ~/.openclaw/state/openclaw.sqlite 'pragma integrity_check'
```

El `integrity_check` tiene que imprimir `ok`.

### 4. Restaurar los extras

```sh
mkdir -p ~/restauracion/extras && tar -xzf ~/restauracion/"$E" -C ~/restauracion/extras
X=~/restauracion/extras/Users/gon
cat "$X/respaldo-completo/RESPALDO-EXTRAS.txt"
for r in Library/LaunchAgents goncloud-autoupdate .claude .claude.json .ssh .zshrc .openclaw-state .local/bin bin; do
  [ -e "$X/$r" ] && ditto "$X/$r" "$HOME/$r"
done
chmod 700 ~/.ssh
```

`RESPALDO-EXTRAS.txt` dice qué no existía en la Mini ese día. Lo que no existía tampoco se restaura.

### 5. Cargar los LaunchAgents

Antes de cargar el gateway, comprueba que el node de su plist existe en esta Mac:

```sh
plutil -p ~/Library/LaunchAgents/ai.openclaw.gateway.plist | grep -m1 node
```

Si la ruta no existe, regenera el plist con `~/.openclaw/bin/openclaw gateway install --force`. Después carga todos:

```sh
mkdir -p ~/Library/Logs/openclaw ~/Library/Logs/goncloud
for p in ~/Library/LaunchAgents/ai.openclaw.*.plist ~/Library/LaunchAgents/ai.goncloud.*.plist; do
  launchctl bootstrap gui/$(id -u) "$p"
done
```

Esto también reactiva este respaldo diario (`ai.goncloud.respaldo-completo`).

### 6. Rehacer los inicios de sesión

- **CLI `claude`.** Su sesión vive en el llavero. Corre `claude` y luego `/login`.
- **Proveedores de modelos.** `~/.openclaw/bin/openclaw models status --probe` dice cuáles fallan. Vuelve a entrar con `~/.openclaw/bin/openclaw models auth login --provider <proveedor>`.
- **Navegador de claw.** Abre el perfil `claw` y vuelve a iniciar sesión en Seller Central .com y .com.mx, Flex y Gmail.
- **WhatsApp**, si está configurado y dejó de recibir. Vuelve a vincularlo.
- **Plugins.** Si el restore avisó de plugins sin `node_modules`, corre `~/.openclaw/bin/openclaw plugins update <id>` por cada uno.

### 7. Comprobar

Cada comprobación tiene su resultado esperado:

```sh
~/.openclaw/bin/openclaw gateway status     # el gateway corre y responde
~/.openclaw/bin/openclaw models status      # sin proveedores en error
~/.openclaw/bin/openclaw agent --agent main --timeout 180 --message "Responde solo: listo"   # contesta "listo"
~/.openclaw/bin/openclaw cron list --all    # las automatizaciones de la Mini (43 al 2026-10-15)
```

Manda un mensaje a claw por Telegram y espera su respuesta. Por último, corre el respaldo una vez con `launchctl kickstart gui/$(id -u)/ai.goncloud.respaldo-completo` y revisa que el log termine en `terminado sin fallas`.

## Hermes

La PC de Hermes sube `hermes-backup-AAAAMMDD.tar.gz` al mismo receptor, con la familia `hermes`. Cómo se respalda y cómo se reinstala Hermes está en el README de goncloud-hermes, sección [Respaldo y reinstalacion](https://github.com/gon0801/goncloud-hermes#respaldo-y-reinstalacion).
