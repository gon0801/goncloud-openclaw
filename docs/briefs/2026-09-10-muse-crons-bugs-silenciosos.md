# Brief para Muse — cerrar bugs silenciosos de los crons de packing (Telegram + mail)

Fecha: 2026-09-10 (~06:40Z). Lead: Claude (revisa 1 vez al final). Implementa: Muse.
Origen: auditoria del lead sobre los 5 jobs de OpenClaw + scripts en gonserver. Hallazgos numerados #1..#9.

## 0. Contexto y accesos (no asumir nada mas)

- Los crons NO viven en este repo. Viven en el gateway Windows (`C:\Users\ehven\.openclaw`, sqlite).
  Desde la Mac de David se operan con `~/.openclaw/bin/openclaw cron <list|get|runs|edit|add|rm|show>`
  (modo remote, ya configurado). Si corres en otro host, lo unico que NO cambia son los UUIDs y rutas remotas.
- gonserver: `ssh gonserver` desde la Mac entra como **root**. El cron entra como **claw** (`claw@goncloud`).
  Todo script de census se prueba como claw: `runuser -u claw -- bash <script>`. NUNCA como root (deja temporales de root en /tmp y rompe al cron).
- Jobs (UUID → nombre → schedule):
  - `76b279ba-1a21-4d74-9a56-41da9514559e` packing-extras-7h — `0 7 * * 1-5` CDMX (13:00Z)
  - `9e907473-a32e-46e6-b2bf-180aadf3f14c` packing-extras-11h — `0 11 * * 1-5` CDMX (17:00Z)
  - `eeae2a74-6389-4e83-a80a-d0ae6cdc7988` packing-digest-20h — `0 20 * * 0-4` CDMX (02:00Z)
  - `71534695-f3d6-4e86-8481-303d7487298e` verif-7h-v12-estreno — at 2026-09-10T13:12Z (one-shot)
  - `74e9a2e7-076a-49f0-9245-96300ab049ac` report-7h-estreno — `25,45 9 10 9 *` America/New_York (agente main)
- Scripts vivos en gonserver: `/home/claw/packing/send_pers_photo.sh`, `/home/claw/send_sales_digest.sh`,
  `/home/claw/send_sales_digest_gon.sh`, `/tmp/census_v2_pipe.sh` (copia; el MASTER esta en Windows:
  `C:\Users\ehven\.openclaw\workspace-operaciones\packing\tmp\census_v2_pipe.sh` y se scp-ea en cada corrida).
- Skills vivas: en Windows `C:\Users\ehven\.openclaw\agents\<agente>\agent\workshop-skills\...`; este repo tiene el snapshot en `agents/...`. Aplicar en ambos.
- API de Telegram: `TG_API_HOST=api.telegram.org` (los scripts la arman como `https://$TG_API_HOST/bot$TOKEN/...`; en tests se sustituye por el mock local).

## 1. Guardrails (violar uno = entrega rechazada)

1. **PROHIBIDO `openclaw cron run` (force) sobre 76b279ba / 9e907473 / eeae2a74 / 71534695 / 74e9a2e7.** Disparan mails y Telegram reales. La corrida real es del schedule/lead.
2. **NUNCA imprimir ni loguear** el token ni los chat ids de `/home/claw/.secrets/telegram-sales.env`. Ni `cat` del .env. Solo nombres de variables.
3. Mensajes de cron: **UNA sola linea, ASCII puro (7-bit)**, editados con `cron edit <uuid> --message "$(cat archivo)"` desde archivo, nunca retipeados. Antes de cada edit: backup `cron get <uuid> --json > docs/cron-messages/backup/<uuid>.json`. Despues: verificar en el echo/`cron get` que (a) la primera linea trae el marker `v14`, (b) `grep -c 'Â'` = 0, (c) `configRevision` cambio, (d) longitud ~ la esperada (un mensaje que perdio 90% del largo = truncado → restaurar backup y parar).
4. No tocar los otros 9 jobs (heartbeat, memory-dreaming, skill-collection-review x7).
5. No editar `personalizadas-sent.json` a mano. No borrar `/tmp/cv3.sh` ni `/tmp/census_v2_pipe.sh` antes del estreno.
6. Ventanas cerradas para editar mensajes (hay corrida en curso): 12:55–13:35Z (7h), 13:40–14:05Z (verif), 16:55–17:25Z (11h), 01:55–02:25Z (20h).
7. Scripts para gonserver: escribirlos en el repo y subirlos con `scp`. **NO** via write tool del gateway (corrompe `$( )`). Para el census (master en Windows) evitar `$( )` dentro del script (usar `$$`, tempfile + `read`), porque el canal de escritura de Windows lo corrompe.
8. Tests: cada fix trae su prueba y **debe fallar sin el fix y pasar con el fix** (correr ambas y pegar la salida). Verde sin rojo previo no cuenta.
9. Repo: rama desde `origin/main` (`git fetch` primero), commits Conventional (`fix:`/`docs:`), `pre-commit run --all-files` antes del PR, un solo PR. El lead cierra.

## 2. Fases y orden

**Fase A — antes de 12:30Z de hoy (protege el estreno de 13:00Z). Son flags + 1 script; bajo riesgo.**
A1 (#1) failure-alert en los 3 crons. A2 (#2) reprogramar y blindar el verif. A3 (#4) reescribir `send_sales_digest.sh`.

**Fase B — despues de 13:35Z (ya corrio el 7h) y fuera de las ventanas del punto 1.6.**
B1 (#1b #3 #7 #8 #9) mensajes v14 de los 3 crons + timeout del 20h. B2 (#3) report job. B3 (#5) census v4c. B4 (#6) `send_pers_photo.sh` v2 + tests. B5 skills + PR.

Si por hora ya no cabe la Fase A completa: hacer A2 y A1 (son 4 comandos) y avisar al lead.

## 3. Tareas

### A1 (#1) Alertas de fallo en los 3 crons de packing
Hoy: `delivery.mode=none`, sin failureAlert → un run con error (timeout, modelo caido, restart) no avisa a nadie. Evidencia: 9-sep 13:00Z el 7h termino `ok` en 125 s sin hacer nada.
```
for id in 76b279ba-1a21-4d74-9a56-41da9514559e 9e907473-a32e-46e6-b2bf-180aadf3f14c eeae2a74-6389-4e83-a80a-d0ae6cdc7988; do
  ~/.openclaw/bin/openclaw cron edit $id --failure-alert --failure-alert-channel telegram --failure-alert-account-id default \
     --failure-alert-to 6470689715 --failure-alert-after 1 --failure-alert-cooldown 1h --failure-alert-mode announce
done
```
(`--failure-alert*` existe en `cron edit --help`; en `cron add --help` no aparece → crear y luego editar.) Verificar con `cron get <id> --json` que aparece el bloque `failureAlert`.
**Test T1 (discrimina):** crear un job temporal de tipo command que falle (`cmd /c exit 1`; consultar `cron add --help` para la forma), sin failure-alert → `cron run` → `cron runs` muestra `status=error` y `lastFailureNotificationDeliveryStatus=not-requested` (rojo). Aplicar los mismos flags al temporal → `cron run` → David recibe el aviso en Telegram y `lastFailureNotificationDeliveryStatus=delivered` (verde). `cron rm` del temporal. Pegar ambos `cron runs`.

### A2 (#2) verif-7h-v12-estreno: no correr encima del 7h ni fallar su delivery
Hoy: dispara 13:12Z, 12 min despues de arrancar el 7h (que dura 10–17 min) → lee sesion a medias, su paso (3) manda "RECOVERY MANUAL" → mail/Telegram duplicados. Y su delivery `announce -> last` ya esta marcada por el gateway como "will fail-closed: Refusing implicit isolated cron delivery".
1. Mover a `2026-09-10T13:40:00Z` (ver `cron edit --help` para el flag de `at`; si no es editable: `cron get --json` → guardar message → `cron rm` → `cron add` con el mismo message, `--agent operaciones --session isolated --no-deliver --delete-after-run`).
2. `--no-deliver` (ya reporta a Claw por sessions_send en su paso 5).
3. Editar message: `census v12` → `census v13`; insertar antes de `(3) Si fallo,` el texto:
   `(2b) Si la corrida 7h SIGUE EN CURSO (sin reporte final en sessions_history o con actividad en los ultimos 5 min): NO hacer recovery ni reenviar nada; crear con la tool automations un wakeup at +15 min con este mismo mensaje y terminar. `
**Verificacion:** `cron show 71534695…` ya no muestra "fail-closed"; `next` = 13:40Z; message contiene `(2b)`.

### A3 (#4) `send_sales_digest.sh`: manda a Wide y no verifica
Hoy el loop es `TELEGRAM_CHAT_ID_2` + `TELEGRAM_CHAT_ID_CUSTOM` (Isabel + **Wide**); la regla vigente es digest → Gon + Isabel, NUNCA Wide. La skill `telegram-bot-send` lo recomienda "adaptar". Reescribir a `/home/claw/send_sales_digest.sh <archivo_utf8>` (fuente en repo `scripts/gonserver/send_sales_digest.sh`):
- `set -u`; `MSG="$(tr -d '\r' < "$F")"`; abortar si vacio o `${#MSG} > 4096` (`ERR_MSG_LARGO`).
- `TG_API_HOST="${TG_API_HOST:-api.telegram.org}"` y `TG_SCHEME="${TG_SCHEME:-https}"` (para test con mock: `TG_SCHEME=http TG_API_HOST=127.0.0.1:PORT`).
- `TG_ENV="${TG_ENV:-/home/claw/.secrets/telegram-sales.env}"`.
- loop SOLO `"$TELEGRAM_CHAT_ID" "$TELEGRAM_CHAT_ID_2"`; `--data-urlencode` x3; por chat exigir `"ok":true` y extraer `message_id`; imprimir `DIGEST_OK chat#N mid=…` / `DIGEST_ERR chat#N: <160 chars>`; final `DIGEST_OK2 ids:…` exit 0, si no `DIGEST_PARCIAL ok:n/2` exit 1.
- Borrar `/home/claw/send_sales_digest_gon.sh`. `chmod 755`. Subir con scp, no con write tool.
**Test T2 (mock, sin mandar nada real):** mock HTTP en gonserver (python3, puerto local) que registra cada POST (path, chat_id, len(text)) y responde `{"ok":true,"result":{"message_id":N}}`; correr con el mock y un env de prueba con valores dummy (crear `/tmp/tg_test.env` propio, NO el real). Rojo (script viejo, parcheado solo con el host del mock): el mock ve 2 POST con los chat_id de `_2` y `_CUSTOM`. Verde (nuevo): 2 POST con `_ID` y `_2`, `DIGEST_OK2`, exit 0. Extra: mock que responde `ok:false` en el 2do → `DIGEST_PARCIAL`, exit 1; mensaje de 4097 chars → `ERR_MSG_LARGO` sin ningun POST; archivo con CRLF → el mock recibe texto sin `\r`.

### B1 (#1b #3 #7 #8 #9) Mensajes v14 de 7h / 11h / 20h
Obtener cada message con `cron get <uuid> --json` (`payload.message`), aplicar reemplazos con un script python (no a mano), guardar como `docs/cron-messages/<nombre>.v14.txt` (una linea), y `cron edit <uuid> --message "$(cat …)"`. El script debe **abortar si un ancla no aparece exactamente 1 vez** y, al final, asertar: sin `\n`, todos los chars < 128, primera linea contiene `v14`, longitud >= 95% de la original + lo agregado.

Anclas y reemplazos (texto exacto; ASCII):
- (todos) `v13 single-line` → `v14 single-line`; `CENSUS V2 v4b con gate bash` → `CENSUS V2 v4c con gate bash`; caracter `—` (U+2014) → `-`.
- (todos, #1b) `el run ABORTA con ALERTA inmediata a David y Claw por Telegram, NUNCA declara silencio;` →
  `el run ABORTA con ALERTA inmediata a David via tool message (cuenta operaciones, al owner telegram:6470689715; NO depende de exec ni ssh) y a Claw via sessions_send agent:main:main, NUNCA declara silencio;`
- (todos, #7) `verificar en Enviados que se cerro el compose` →
  `antes de enviar confirmar que existe chip del destinatario (click en div[role=option]; Enter solo puede dejar el destinatario sin chip y el send falla en silencio); verificar entrega: en #drafts NO queda borrador con el asunto y en #sent el asunto aparece en una fila tr[role=row] (NUNCA usar body.innerText ni el cierre del compose como prueba)`
- (todos, #4) desde `Telegram digest a Gon (TELEGRAM_CHAT_ID) e Isabel (TELEGRAM_CHAT_ID_2) via source /home/claw/.secrets/telegram-sales.env y curl sendMessage parse_mode=HTML por ssh en gonserver, nunca imprimir token ni chat ids; NUNCA a Wide en el digest;` →
  `Telegram digest SOLO via helper /home/claw/send_sales_digest.sh <archivo_utf8 subido por scp a /tmp> (manda a Gon e Isabel, exige ok:true en ambos, exit 1 si falla; NUNCA curl a mano, nunca imprimir token ni chat ids; NUNCA a Wide en el digest);`
- (7h y 11h, #3) `--set con resumen. Nunca inventar datos;` →
  `--set con resumen + reportar a Claw (agente main) via sessions_send agent:main:main el resumen de lo enviado (a quien, que incluyo, personalizadas con sus msg ids) o el silencio verificado (sentinels). Nunca inventar datos;`
- (7h, #8) `(dedup: no reenviar lo ya reportado hoy).` → `(dedup: no reenviar lo ya reportado hoy). GUARD: si D != fecha CDMX de hoy, el par de anoche no existe (fallo del 20h): ALERTA a David via tool message y ABORTAR, nunca continuar con baseline vieja.`
- (11h, #8) `(incluye extras de las 07:00 y cualquier corrida previa del dia: no reenviar nada ya reportado).` → mismo texto + ` GUARD: si D != fecha CDMX de hoy, el par de anoche no existe (fallo del 20h): ALERTA a David via tool message y ABORTAR, nunca continuar con baseline vieja.`
- (20h, #9) ademas `cron edit eeae2a74… --timeout-seconds 3600` (hoy no tiene timeout; 7h/11h si).
**Verificacion:** por job, `cron get --json` post-edit: primera linea con `v14`, `grep -c 'Â'`=0, `configRevision` distinto al backup, y `python3 -c` que confirme que las 5–7 anclas nuevas estan presentes 1 vez. Pegar las 3 salidas.

### B2 (#3) report-7h-estreno
Su message busca `sessions_history sessionKey=agent:operaciones:main`, pero el 7h corre isolated y (hasta B1) no reporta a Claw; su plan B (`exec openclaw automations …`) queda denegado tras restarts → falso "no pude confirmar". Y `25,45 9 10 9 *` sin ano revive el 10-sep-2027.
- Editar message: `sessions_history sessionKey=agent:operaciones:main limit=8` → `sessions_history sessionKey=agent:main:main limit=8 (el 7h y el verif reportan ahi via sessions_send)`.
- Despues de 14:00Z: `cron get 74e9a2e7…`; si sigue existiendo (main no lo borro) → `cron rm`. Pegar evidencia.

### B3 (#5) census_v2_pipe.sh v4c (MASTER en Windows + copia en gonserver)
Bugs: linea 15 `PGPASSWORD="***"` literal (lee el pgpass a `$PASS` y no lo usa; funciona hoy solo porque el contenedor acepta loopback sin password — dia que se endurezca pg_hba, falla); temporales fijos `/tmp/.cv2q1..q3,.cv2q2b` y `/tmp/.cv2p` (si alguien corre como root, claw ya no puede escribirlos → `tee: Permission denied` → CENSUS_V2_FAIL; `.cv2p` nace 644 con el password dentro).
Cambios (sin `$( )` en todo el archivo):
- `umask 077` al inicio; `T=/tmp/cv2.$$; mkdir -m 700 "$T"; trap 'rm -rf "$T"' EXIT` (ademas del trap ERR existente — combinarlos) y todos los temporales dentro de `$T`.
- `-e PGPASSWORD="$PASS"`.
- Header: `v4c — fixes lead 10-sep: PGPASSWORD real, temporales por PID (mktemp sin $( )), umask 077`.
- Guardar en repo `scripts/gonserver/census_v2_pipe.sh`; subir con scp a gonserver `/tmp/census_v2_pipe.sh`; para el master en Windows: si no tienes acceso al FS de Windows, dejar en el PR la instruccion de 1 linea para que David copie el archivo a la ruta master (indicar sha256).
**Test T3 (discrimina; como claw, read-only SQL):** (a) `runuser -u claw -- bash /tmp/census_v2_pipe.sh 2026-09-10` → 4 sentinels + `CENSUS_V2_OK`, exit 0, y `ls /tmp/cv2.*` vacio al terminar. (b) Rojo con v4b: correr una vez como root (`bash /tmp/census_v2_pipe.sh 2026-09-10`) y luego como claw → `Permission denied`/`CENSUS_V2_FAIL`. Con v4c, la misma secuencia pasa. Limpiar despues: `rm -f /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b` **solo si son de root** (los de claw se dejan). (c) `grep -c '\$(' census_v2_pipe.sh` = 0.

### B4 (#6) send_pers_photo.sh v2
Bugs: si el `python3` que marca el json falla, igual imprime `ENVIADA_OK3` y exit 0 (cada corrida siguiente re-manda 3 fotos "con exito"); `-F caption="$CAPTION"` con caption que empiece en `<` o `@` lo interpreta curl como archivo; exito parcial (2/3) no se registra → el reintento duplica.
Cambios (fuente en repo `scripts/gonserver/send_pers_photo.sh`, subir con scp a `/home/claw/packing/`):
- `TG_API_HOST` / `TG_SCHEME` / `TG_ENV` como en A3, y `PDIR="${PDIR:-/home/claw/packing}"`.
- `--form-string chat_id=… --form-string parse_mode=HTML --form-string caption="$CAPTION"` (conservar `-F photo=@"$JPG"`).
- Registro parcial por INDICE de chat (1=Gon,2=Isabel,3=Wide; nunca el chat id): json `{"<order>": {"sent_at_utc":…, "msg_ids":[…], "ok3":bool, "partial":{"1":mid,"2":mid}}}`. Dedup: `ok3:true` → `YA_ENVIADA`; si hay `partial`, saltar esos indices y mandar solo los faltantes.
- Escritura atomica: python escribe a `$JSON.tmp` y `os.replace`; si python sale != 0 → `echo "ERR_JSON_WRITE <order> (fotos ENVIADAS, json NO marcado: marcar a mano)"; exit 2` — NUNCA imprimir `ENVIADA_OK3` en ese caso.
- Mantener salidas `YA_ENVIADA | ENVIADA_OK3 | ERR_NO_LOCK | ERR_PARCIAL | ERR_NO_JPG`.
**Test T4 (mock, sin fotos reales; correr como claw con `PDIR=/tmp/pp_test.$$`, `TG_ENV=/tmp/tg_test.env` dummy, mock local):**
 (a) mock ok x3 → `ENVIADA_OK3`, json con la orden; (b) rerun → `YA_ENVIADA` y el mock NO recibe POST; (c) mock falla el 3ro → `ERR_PARCIAL`, json con `partial {1,2}`; rerun → el mock recibe SOLO 1 POST (chat#3) → `ENVIADA_OK3`; (d) `chmod 555 $PDIR` → rojo (v1): imprime `ENVIADA_OK3` y exit 0; verde (v2): `ERR_JSON_WRITE`, exit 2; (e) caption que empieza con `<b>x` y otro con `@x`: el mock recibe el caption completo (rojo v1: curl error / caption vacio). Pegar salidas rojo+verde de (d) y (e) como minimo.

### B5 Skills + repo
- `agents/main/agent/workshop-skills/telegram-bot-send/SKILL.md`: pitfall final → el helper es `/home/claw/send_sales_digest.sh <archivo>` y manda a Gon+Isabel; borrar la mencion a `_CUSTOM` en el ejemplo de digest; sendPhoto: `--form-string` para caption/chat_id.
- `agents/operaciones/agent/workshop-skills/telegram-send-gonserver/SKILL.md`: mismo cambio + nota "caption con `<` o `@` inicial requiere `--form-string`".
- `agents/operaciones/agent/workshop-skills/gmail-compose-rich-mail/SKILL.md` paso 3 y 6: alinear con `gmail-html-email` (confirmar chip; cierre del dialogo no es prueba; verificar fila en Enviados + Borradores vacio).
- `agents/operaciones/agent/workshop-skills/openclaw-cron-jobs/SKILL.md`: agregar 1 linea: "todo job de negocio lleva `--failure-alert` a David; delivery `announce -> last` en isolated falla (fail-closed): usar `--no-deliver` o `--to` explicito".
- Aplicar tambien en las copias vivas de Windows (o dejar instruccion para David si no hay acceso).
- Agregar `docs/cron-messages/*.v14.txt` y `scripts/gonserver/*` + `scripts/gonserver/tests/*.sh` (los mocks y tests T2/T4 como scripts reproducibles).

## 4. Entrega (en el PR)

1. Tabla hallazgo → fix → evidencia (salida rojo/verde de T1–T4, `cron get` post-edit de los 5 jobs con `configRevision`).
2. Lo que NO se pudo hacer y por que (ej. master de Windows), con la instruccion exacta para David.
3. Hora UTC de cada edit de cron (para cruzar con las ventanas del 1.6).
4. Sin narrativa, sin repetir este brief.
