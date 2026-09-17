# TDD del carril P (Fase 7) — rojos pegados

## 7.1 — rojo primero, sin validador

Commit 929ed08: `progress.test.ts` se commitea ANTES de que exista `lib.ts`.
Salida verbatim (`71-rojo.txt`, recorte):

```
✖ progress.test.ts (44.88ms)
  code: 'ERR_MODULE_NOT_FOUND',
  url: 'file:///Users/dn/dev/wt-f7-P/tablero-runbook/lib.ts'
ℹ pass 0
ℹ fail 1
```

## 7.3 — mutantes (todos ROJO; batería 32 pass en ese commit)

Ejecutado por `73-mutantes.sh`, salida en `73-mutantes.txt`:

| Mutante | Resultado |
|---|---|
| quitar `esc()` (script en titulo/repo/check aparece literal) | ROJO |
| invertir truncar/escapar (entidad cortada) | ROJO |
| quitar el truncado | ROJO |
| aceptar un `estado` fuera de lista | ROJO |
| aceptar `fase` con `/` o `..` | ROJO |
| aceptar `repo` con `;` o que empiece con `-` | ROJO |
| perder eventos previos al fusionar | ROJO |

Detalle del discriminante del orden truncar/escapar (mutante invertir):

```
✖ ninguna entidad queda cortada: truncar PRIMERO, escapar después (mutante invertir orden)
ℹ pass 31
ℹ fail 1
```

## 7.5 — mutantes (todos ROJO; batería 60 pass en ese commit)

Ejecutado por `75-mutantes.sh`, salida en `75-mutantes.txt`:

| Mutante | Resultado |
|---|---|
| quitar el flag `enabled` | ROJO (pass 58 / fail 2) |
| aceptar repo envenenado (`a/b; calc.exe`, `--template x`) | ROJO (pass 58 / fail 2) |
| aceptar `ghPath` en `.cmd` | ROJO (pass 59 / fail 1) |
| quitar el kill por llamada (timeout/SIGKILL de execFile) | ROJO (pass 59 / fail 1) |
| sin NINGÚN kill (ni por llamada ni verdugo) | ROJO (pass 57 / fail 1, cae por timeout) |

## VERIFY final (HEAD 28e8c9b)

- `bash scripts/run-checks.sh` → `TODO VERDE`, exit 0 (`verify-run-checks.txt`).
- `cd tablero-runbook && node --test` → `ℹ tests 60 · pass 60 · fail 0` (`verify-node-test.txt`).
