# TDD carril M — evidencia

## 13.5 — convencion de dos copias

### Rojo primero (antes de corregir el .txt)
```
ROJO: (1) docs/crons/verif-digest-20h.md fence != verif-digest-20h.v1.txt: las dos copias divergieron (el aplicador usaria el .txt)
EXIT:1
```
Causa: el .txt aun decia "1 hora adelante de CDMX"; el .md (y el cron vivo) ya tenian la correccion del 2026-09-12 (pedir NY+CDMX al sistema, sin restar).

### Verde despues
```
ok (1): verif-digest-20h.md ↔ verif-digest-20h.v1.txt (fence=txt, id vivo, cierre en linea propia)
ok (1ex): verif-sync-repos en MD_SIN_TXT (sin .txt por ahora)
...
ok (3): mutante de una palabra deja rojo
ok (4): un .txt nuevo sin .md deja rojo
TODO VERDE: crons-dos-copias
```

### Mutantes
- Cambiar una palabra del .txt (PROPOSITO→PROPOSITO_X) → mismo ROJO de (1).
- Agregar `cron-fantasma.v1.txt` sin .md → el chequeo (2) sale rojo.

### Formato de id vivo (elegido por M; runbook §atores)
`Id vivo: \`<uuid>\`.` en el encabezado de ambos `.md`:
- verif-digest-20h → c812d541-bc38-4a5d-9bef-49239a9cee03
- verif-sync-repos → 2d763be5-6390-4ccf-a3a4-621c91c41e94

## 13.2 — (pendiente)

## 13.2 — sync avisa skills

### Rojo primero (antes de las marcas en sync-repos.ps1)
```
ROJO: (0) faltan marcas # >>> skills-cambiadas — la funcion no se puede extraer
EXIT:1
```

### Verde despues
```
ok (0)..ok (6)
TODO VERDE: sync-avisa-skills
TODO VERDE: crons-dos-copias  (verif-sync-repos ya no es excepcion; apareado a v2.txt)
```

### Mutantes
- Llamado SKILLS movido despues del commit → fuera de la ventana de (2).
- Quitar el try/catch del flujo → rojo en (2)/(0).
- Funcion contra repo temporal: solo `s/SKILL.md` (no `otro/no-skill.txt`).
- throw forzado → `SKILLS error:` y el ciclo sigue.

### Aplicador
`APLICAR_VIGIA_SYNC.sh --test` (seco) escribio `.pre.json`/`.post.json` con `payload.message` == v2.txt y agentId/schedule/toolsAllow/enabled intactos. No edito el gateway.

## r1 — el mutante «quitar el llamado» ahora muere

### Antes del arreglo (reproduccion)
Borrar la linea `$skillsSnap = Get-OpenclawSkillsCambiadasStaged -RepoRoot $r` o reemplazarla por `$skillsSnap = $null` dejaba el test en VERDE (rc=0): el chequeo (2) anclaba solo en `SKILLS error:` (el catch), que sobrevivia.

### Mutante A (linea borrada) → ROJO
```
ROJO: (2) falta el llamado Get-OpenclawSkillsCambiadasStaged -RepoRoot $r en el flujo (borrarlo o anularlo a $null debe dejar rojo aqui)
MUT_A_EXIT:1
```

### Mutante B (`$skillsSnap = $null`) → ROJO
```
ROJO: (2) falta el llamado Get-OpenclawSkillsCambiadasStaged -RepoRoot $r en el flujo (borrarlo o anularlo a $null debe dejar rojo aqui)
MUT_B_EXIT:1
```

### Restituido → VERDE
```
ok (2): el llamado Get-OpenclawSkillsCambiadasStaged -RepoRoot $r va entre la guardia y el commit (linea 128)
...
TODO VERDE: sync-avisa-skills
TODO VERDE: crons-dos-copias
```

## r2 — dos huecos del test de dos copias

### Hueco 1 (antes): mutantes no ejercían el chequeo (1)
Con la comparación `[ "$got" = "$want" ]` anulada a `:`, el test seguía VERDE e imprimía «ok (3)».

### Hueco 1 (despues): anular la comparación → ROJO
```
ROJO: (3) mutante: cambiar una palabra del .txt debio hacer fallar el chequeo (1) real y paso
EXIT:1
```

### Hueco 2 (antes): cualquier uuid del .md bastaba
Borrar la linea `Id vivo: …` dejaba VERDE (encontraba el uuid del job en el cuerpo).

### Hueco 2 (despues): sin la linea Id vivo → ROJO
```
ROJO: (1) docs/crons/verif-digest-20h.md no declara su id vivo (falta la linea 'Id vivo: <uuid>')
EXIT:1
```

### Restituido
```
ok (3): mutante de una palabra deja rojo el chequeo (1) real
ok (4): un .txt nuevo sin .md deja rojo el chequeo (2) real
TODO VERDE: crons-dos-copias
TODO VERDE: sync-avisa-skills
```

## r3 — ventana del log, --test D1/D2, y el ? de C

### Hueco 1: tail-80 perdia SKILLS
```
{ echo "<linea SKILLS>"; seq 80; } | tail -80 | grep -c " SKILLS "  → 0
{ echo "<linea SKILLS>"; seq 80; } | tail -400 | grep -c " SKILLS " → 1
```
Arreglo: PASO 1 y PASO 3b usan la misma ventana `tail -400` (declarada: cubre varios ciclos; minimo obligatorio).

### Hueco 3: "?" restaurado
`"Lo reviso ahora? Responde SI y lo veo."` (como el v1).

### Hueco 2: --test declara D1/D2
```
bash docs/cron-messages/APLICAR_VIGIA_SYNC.sh --test  → EXIT 0
recorrido D1/D2 impreso (vigia-sync-prueba-D1/D2, --tools exec, LOG=prueba, SKILLS de 43097da)
SECO: no se crearon jobs. Falta la corrida real en Q2:
  VIGIA_SYNC_EJECUTAR=1 docs/cron-messages/APLICAR_VIGIA_SYNC.sh --test
```

### Tests
```
TODO VERDE: crons-dos-copias
TODO VERDE: sync-avisa-skills
```

## r4 — D1/D2 escriben fixture, aserciones y rm verificado

### Huecos (antes)
1. Solo NOTAs: D2 leia el mismo log que D1.
2. Sin aserciones: exit 0 aunque D1 no nombre verifier.
3. `cron rm` fallido → exit 0.

### Arreglo
- `escribir_log_prueba` via `cron add --command` (cola+SKILLS antes de D1; cola sin SKILLS antes de D2).
- `vigia_sync_prueba_assert.py`: assert-d1 / assert-d2 / assert-rm.
- `rm_y_verificar`: rm + cron list + assert-rm.

### Test en seco (`test-aplicar-vigia-sync-prueba.sh`)
```
ok (1): D1 con verifier+archivos → PASS
ok (2): D1 vacio → FAIL
ok (3): D2 sin aviso D → PASS
ok (4): D2 con aviso D → FAIL
ok (5): rm fallido → FAIL
ok (6): rm OK pero sigue en list → FAIL
ok (7): rm verificado → PASS
ok (8): mutante que acepta D1 vacio queda expuesto
ok (9): el aplicador escribe fixture, aserta resultado y verifica rm
TODO VERDE: aplicar-vigia-sync-prueba
```
Mutante: quitar `escribir_log_prueba 1 D1` → ROJO (9).

### --test seco
EXIT 0; declara escritura de fixture + asserts; no crea jobs (corrida real: VIGIA_SYNC_EJECUTAR=1).

## r5 — aserciones estrictas y franja de silencio

### Repros (antes → ahora EXIT 1)
```
assert-d1 {status:error, … verifier …} → ASSERT_FAIL: run no exitoso (completionStatus=failed)
assert-d2 {} → ASSERT_FAIL: sin entradas
assert-rm … unknown → ASSERT_FAIL: UNKNOWN: no pude leer cron list
```

### Legitimos (EXIT 0)
d1-ok con `VIGIA SYNC SKILLS agentes=verifier n=…`; d2-ok callado; rm absent; rm fallido → 1.

### Franja
`VIGIA_SYNC_EJECUTAR=1 --test` se rehúsa entre 23:00-08:00 CDMX (`en_franja_silencio_cdmx`).

### Test
`TODO VERDE: aplicar-vigia-sync-prueba` (casos 1-12).

## r6 — franja conductual, contrato UNA linea, jobs=[]

### Hueco 1: franja solo por grep
Antes: `grep en_franja_silencio_cdmx` → VERDE aunque `if false; then` anule el guard.
Ahora: copia hermetica bajo scratch; mock dentro → exit≠0 + «franja de silencio»; mock fuera → no bloquea; guard anulado → expuesto.

### Hueco 2: contrato partido con DOTALL
```
assert-d1 summary="VIGIA SYNC SKILLS agentes=verifier\ntexto n=1 skill.md" → EXIT 1
```
`_linea_contrato_d1` exige UNA linea; mutante DOTALL queda expuesto.

### No-bloqueante: jobs=[]
```
list-status {"jobs":[]} → absent   (antes: unknown via `jobs or d`)
list-status sin clave jobs → unknown
```

### VERIFY
```
ok (3b): D1 contrato partido → FAIL
ok (3c): mutante DOTALL …
ok (10b): jobs=[] → absent; mutante jobs-or …
ok (13): franja conductual (in→abort, out→ok); guard anulado queda expuesto
TODO VERDE: aplicar-vigia-sync-prueba
TODO VERDE: crons-dos-copias
TODO VERDE: sync-avisa-skills
bash scripts/run-checks.sh → exit 0
```

## Q2 — aplicador REAL contra el gateway (2026-09-20)

Espera: sleep hasta `02:26:05Z` (fuera de ventana cerrada 01:55–02:25Z; CDMX 20:26, fuera de silencio 23–08).

### 1. Edit vivo
```
bash docs/cron-messages/APLICAR_VIGIA_SYNC.sh → EXIT 0
backup: 2d763be5-…20260920T022705Z-74654.{pre,post}.json
message post == verif-sync-repos.v2.txt (8157 B)
agentId/schedule/toolsAllow/enabled intactos vs pre
```

### 2. D1/D2 (VIGIA_SYNC_EJECUTAR=1 --test)
Intento 1–2: ABORTO `write-job … no corrio` — `cron run` sale ≠0 porque el job de escritura iba con delivery announce→last (fall-closed) aunque el comando escribía el log (stdout `1`).
Arreglo mínimo: `--no-deliver` en `escribir_log_prueba` (igual que D1/D2).
Reintento:
```
fixture D1 OK → D1 id=42ee6ef5… status=ok succeeded 74s → ASSERT_OK assert-d1 + rm absent
fixture D2 OK → D2 id=2f5b83bc… status=ok succeeded 44s → ASSERT_OK assert-d2 + rm absent
PRUEBA D1/D2 terminada VERDE
summary D1: CASO D + linea SKILLS verifier + archivos
summary D2: VIGIA SYNC OK ciclo=… (callado en D)
```

### 3. Re-lectura
`openclaw cron get 2d763be5-…` message == post.json == v2.txt.

### 4. Commits
`fix(13.2): --no-deliver en write-jobs del fixture` + `chore(13.2): respaldo pre/post del vigia v2 aplicado`.
