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
