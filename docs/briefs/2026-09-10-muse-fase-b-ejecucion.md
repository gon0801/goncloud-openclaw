# Brief para Muse — ejecutar Fase B (ventana abierta, estreno OK)

Fecha: 2026-09-10 ~13:40Z. Lead: Claude. Implementa: Muse.
Origen: tu propio PR #1 (ya MERGEADO a main, `dbdd2a5`) + brief de fixes `2026-09-10-muse-fixes-revision.md`. Esto es la ejecucion operativa que quedo pendiente (tu seccion F3 + B1/B2/B3/B4 del brief original).

## 0. Contexto (verificado por el lead)

- **Estreno 13:00Z: OK.** Corrida `ok` en 23 min con zai/glm-5.3. Digest a Gon (msg 12946) e Isabel (msg 12947), ambos `ok:true`, sin Wide. Mail verificado en Enviados. Census `CENSUS_V2_OK` con los 4 sentinels. Sin duplicados.
- El verif (13:40Z) lo observa el lead; no lo toques.
- **gonserver ya tiene:** helper `/home/claw/send_sales_digest.sh` v2 vivo, `send_sales_digest_gon.sh` eliminado. `/tmp/census_v2_pipe.sh` sigue en v4b (correcto hasta ahora). `/home/claw/packing/send_pers_photo.sh` sigue en v1 (le toca v2 en B4).
- **El sync de Windows esta caido desde las 03:10Z** (maquina dormida). Todo lo tuyo que viva en Windows (master census, skills) va como INSTRUCCION para David en el PR, no como edicion tuya.
- Rama: tu rama vieja ya se mergeo. Trabaja en rama nueva desde `origin/main` (`git fetch` primero): `git checkout -b chore/fase-b-evidencia origin/main`. Commits Conventional. Un PR chico solo con la evidencia y scripts finales.

## 1. Guardrails (siguen todos los de tu brief original)

- Ventanas cerradas restantes HOY: **16:55-17:25Z** (11h) y **01:55-02:25Z** (20h). Los edits de mensajes v14 tienen que terminar antes de 16:55Z.
- Backup `cron get <uuid> --json > docs/cron-messages/backup/<uuid>.preB.json` antes de CADA edit; verificacion post-edit (marker v14, `grep -c 'Â'`=0, sin chars >127, configRevision cambio, largo esperado).
- Nunca imprimir token ni chat ids. Scripts a gonserver via scp, nunca write tool.
- T3 como claw con `runuser -u claw --`, el rojo controlado como root SOLO lo del paso (b). Limpiar temporales de root despues (solo los de root).
- Tests rojo/verde con salidas pegadas en `docs/cron-messages/evidence/`.

## 2. Tareas (en este orden)

### B-T3 — census v4c en gonserver (primero, gatea lo demas)
1. `scp scripts/gonserver/census_v2_pipe.sh gonserver:/tmp/census_v4c.sh` (NO pises `/tmp/census_v2_pipe.sh` todavia).
2. Verde (a): `ssh gonserver "runuser -u claw -- bash /tmp/census_v4c.sh 2026-09-10"` → 4 sentinels + `CENSUS_V2_OK`, exit 0, `ls /tmp/cv2.*` vacio al terminar. Guardar en `docs/cron-messages/evidence/T3-verde.txt`.
3. Rojo controlado (b): correr UNA vez como root el **v4b** (`bash /tmp/census_v2_pipe.sh 2026-09-10`) y luego como claw el v4b → `Permission denied`/`CENSUS_V2_FAIL`. Luego la MISMA secuencia con v4c pasa. Guardar `T3-rojo.txt`. Limpiar: `rm -f /tmp/.cv2q1 /tmp/.cv2q2 /tmp/.cv2q3 /tmp/.cv2q2b` SOLO si son de root (`ls -la` primero, los de claw se dejan).
4. (c) `grep -c '\$(' scripts/gonserver/census_v2_pipe.sh` = 0 (local, pegalo).
5. Si TODO verde: `ssh gonserver 'cp /tmp/census_v4c.sh /tmp/census_v2_pipe.sh'` y verifica el header v4c en `/tmp/census_v2_pipe.sh`.
6. **Master Windows:** NO tenes acceso (sync caido ademas). Dejar en el PR la instruccion de 1 linea para David: copiar `scripts/gonserver/census_v2_pipe.sh` a `C:\Users\ehven\.openclaw\workspace-operaciones\packing\tmp\census_v2_pipe.sh`, sha256 `2397f675ac5635de310458a8ba06ab37212231f92ea0ceb253473d77b9f66bce`.

### B-v14 — mensajes v14 + timeout (terminar antes de 16:55Z)
7. Correr `docs/cron-messages/APLICAR_FASE_B.sh` (ya incluye: backups, v14 x3 via `gen_v14.py` + `cron edit`, `--timeout-seconds 3600` del 20h, y B2 del report job con el fix del em-dash). Si el script pide pasos manuales, seguirlos tal cual.
8. Verificacion por job (guardrail 3): `cron get --json` post-edit → primera linea `v14`, `grep -c 'Â'`=0, `configRevision` distinto al backup, y python que confirme las anclas nuevas 1 vez. Pegar las 3 salidas en `docs/cron-messages/evidence/B1-postedit-*.txt`.
9. Si algo falla el verify: el aplicador ya hace rollback solo; PARA ahi y reporta, no reintentes a ciegas.

### B-report — report-7h-estreno (despues de 14:00Z)
10. `cron get 74e9a2e7-076a-49f0-9245-96300ab049ac --json`: si el job sigue existiendo (main no lo borro tras sus corridas de 13:25/13:45Z) → `cron rm 74e9a2e7-...` y pegar evidencia. Si ya no existe, constatarlo.

### B4 — send_pers_photo.sh v2 a gonserver
11. `scp scripts/gonserver/send_pers_photo.sh gonserver:/home/claw/packing/send_pers_photo.sh` + `chmod 755`. T4 ya tiene evidencia rojo/verde en el repo de la ronda anterior; aca solo verifica header v2 y `bash -n` remoto. Si la proxima corrida con personalizadas es el 20h (02:00Z), queda cubierta.

### B5 — cierre
12. Commitear evidencia (`T3-*.txt`, `B1-postedit-*.txt`, backups `.preB.json`) en la rama nueva, `pre-commit run --all-files`, push, UN PR chico contra main. En el PR: tabla tarea → evidencia, hora UTC de cada edit de cron (para cruzar ventanas), y la instruccion del master Windows para David.
13. Avisar al lead cuando el PR este arriba. El lead mergea.

## 3. Lo que NO es tuyo
- El verif de 13:40Z, el OAuth de xAI, los patches de modelos M1, y cualquier cosa del gateway fuera de los 4 jobs de packing + report job.
- Si encontras algo roto fuera de este alcance: reportalo en el PR, no lo arregles.
