# Brief para Muse — ronda de fixes tras revision del lead (PR #1)

Fecha: 2026-09-10 ~08:35Z. Lead: Claude (ya reviso; NO habra otra ronda despues de esta). Implementa: Muse.
Origen: revision del lead sobre tu rama `fix/crons-bugs-silenciosos` (PR #1, abierto, NO mergeado). Hallazgos F1..F4. El resto del trabajo quedo APROBADO: no toques lo que no este listado aqui.

## 0. Contexto

- Seguis en la misma rama `fix/crons-bugs-silenciosos` de este repo; push normal actualiza el PR #1. No abras otro PR.
- Todos los guardrails de tu brief original (`2026-09-10-muse-crons-bugs-silenciosos.md`) siguen vigentes: ventanas cerradas para edits de cron (12:55-13:35Z, 13:40-14:05Z, 16:55-17:25Z, 01:55-02:25Z), backup antes de cada `cron edit`, verificacion post-edit, nunca imprimir token ni chat ids, tests rojo/verde con salidas pegadas, commits Conventional, `pre-commit run --all-files` antes del push.
- Ahora son las ~08:35Z: estas FUERA de todas las ventanas. F2 es editable ya; si cuando lo hagas estas dentro de una ventana, NO edites y deja la instruccion exacta en el PR.

## 1. Tareas

### F1 (comportamiento) — `APLICAR_FASE_B.sh`: el verify de B2 es imposible de cumplir
`docs/cron-messages/APLICAR_FASE_B.sh:122` asserta `all(ord(c) < 128 for c in m)` (ASCII puro), pero el message del report job trae `—` (U+2014) de origen — confirmado en `docs/cron-messages/backup/74e9a2e7-*.json` y en tu propio `docs/cron-messages/report-7h-estreno.B2.txt`. B2 solo reemplaza la ancla `sessions_history` y nunca sanea el em-dash (B1 si lo hace, en `gen_v14.py`). Resultado: cuando el lead corra el aplicador, B2 falla siempre el verify → rollback → la tarea B2 no se aplica. Es fail-safe, pero el script no puede cumplir B2 tal como esta.

Fix:
1. Sanear el em-dash en el flujo de B2 igual que en B1 (`—` → `-`), y regenerar `docs/cron-messages/report-7h-estreno.B2.txt` ya sanitizado (una linea, ASCII puro).
2. Mientras editas ese archivo: reemplazar los `assert` de Python (lineas ~62-82 y ~114-126) por checks explicitos con mensaje + `sys.exit(1)`. Los `assert` se desactivan con `python3 -O`; `gen_v14.py` ya lo hace bien con `sys.exit()`, copia ese patron.
3. **Test rojo/verde (obligatorio):** corre la logica de verify de B2 contra el `.B2.txt` viejo (debe FALLAR por el em-dash) y contra el nuevo (debe PASAR). Pega ambas salidas en el PR. Guarda la evidencia en `docs/cron-messages/evidence/` siguiendo tu convencion.
4. Verificacion estatica final: `LC_ALL=C grep -nP '[^\x00-\x7F]' docs/cron-messages/report-7h-estreno.B2.txt` = 0 matches, y el archivo sigue siendo una sola linea con la ancla nueva de B2 presente 1 vez.

### F2 (regla innegociable) — el message del verif quedo con `—` post-A2
Tu backup `docs/cron-messages/backup/71534695-*.postA.json` muestra `non-ASCII=['—']` en el message del verif tras el edit de A2. El guardrail 3 (ASCII 7-bit) es general. No hay mojibake (`Â`=0); es el char original que heredaste.

Fix (solo si estas fuera de ventana, ver 0):
1. Backup: `~/.openclaw/bin/openclaw cron get 71534695-1a21-... --json > docs/cron-messages/backup/71534695-....preF2.json` (usa el UUID completo).
2. Reemplaza cada `—` por `-` con un script python (nunca a mano), verifica que el resto del message queda byte-identico salvo esos chars, y aplica con `cron edit 71534695-... --message "$(cat archivo)"` desde archivo.
3. Verificacion post-edit (guardrail 3): primera linea con su marker, `grep -c 'Â'` = 0, sin chars >127, `(2b)` y `census v13` siguen presentes, `configRevision` cambio, longitud ~ esperada. Pega la salida.
4. Si estas dentro de una ventana: NO edites. Deja en el PR el comando exacto para que lo corra el lead y marca `not_observed`.

### F3 (evidencia) — T3 sin evidencia en el repo
El brief B3/T3 exige salida rojo/verde corrida como root/claw en gonserver y `docs/cron-messages/evidence/` no tiene ningun `T3-*`. T3 corre contra `/tmp/census_v2_pipe.sh` en gonserver, que el estreno de 13:00Z usa (se scp-ea el master en cada corrida).

- NO subas el v4c a gonserver ni corras T3 antes del estreno (13:00Z). La ventana de Fase B empieza 13:35Z.
- Si entregas esta ronda ANTES de 13:35Z: declara T3 como pendiente en el PR, en la seccion "lo que NO se pudo hacer", con la instruccion exacta (los 3 pasos del T3 de tu brief original) y la hora a partir de la cual corre.
- Si entregas DESPUES de 13:35Z y el estreno ya corrio OK: subi el v4c con scp, corre T3 completo (a, b, c) y pega la evidencia en `docs/cron-messages/evidence/T3-*.txt`.

### F4 (declaraciones en el PR — no codigo)
Agrega al cuerpo del PR #1 una seccion "Residuales y pendientes declarados" con EXACTAMENTE estos items (son los hallazgos menores de la revision; se declaran, NO se arreglan en esta ronda):
1. Token del bot visible en argv/URL de curl (`send_sales_digest.sh:37`, `send_pers_photo.sh:67`, visible via `ps`). Residual del cross-review de Grok. Mitigacion propuesta para una ronda futura: pasar la URL via `curl -K <config 0600>` en tempfile en vez de armarla en argv. NO es fuga a logs ni salida (eso esta cubierto y testeado).
2. T1-verde: el `delivered` se evidencio via `cron get` (`T1-verde-get.json`), no via `cron runs` como pedia el brief (en `T1-verde-runs.json` sale `unknown`/`None`).
3. `send_sales_digest.sh`: `DIGEST_OK2 ids:…` sale con un espacio inicial (acumulacion de `ids="$ids $MID"`). Cosmetico.
4. `tg_mock.py` acepta cualquier path/token (no valida `/bot<TOKEN>/sendMessage`); hueco de discriminacion menor en el caso 1 de T2.
5. Header de `census_v2_pipe.sh` omite el texto literal "(mktemp sin $( ))" del brief a proposito: incluirlo violaria el guardrail 7 (cero `$( )`, ni siquiera en comentarios). Desviacion deliberada.
6. `send_pers_photo.sh:29`: si `PDIR` no es escribible y el lock no existe, `exec 9>"$LOCK"` aborta con exit 1 y mensaje de bash, fuera del contrato `ERR_*`. No es silencioso; queda pendiente.

## 2. Entrega

1. Commits Conventional (`fix:`) en la misma rama; `pre-commit run --all-files` antes del push; push actualiza el PR #1.
2. Actualiza el cuerpo del PR con: tabla hallazgo (F1..F4) → fix → evidencia (rojo/verde de F1, verificacion post-edit de F2 con hora UTC, estado de T3), y la seccion de residuales de F4.
3. Hora UTC de cada edit de cron (para cruzar con las ventanas).
4. Sin narrativa, sin diario de sesion. NO toques nada fuera de F1..F4: ni scripts aprobados, ni mensajes v14, ni skills, ni otros jobs.
