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
