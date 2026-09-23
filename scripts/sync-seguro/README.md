# Sync selectivo seguro fuente → runtime (U1)

Lleva el repo principal al runtime Windows por manifiesto positivo, staging
fuera del vivo, validación, reemplazo atómico por archivo y read-back. Bases,
credenciales, sesiones, logs, herramientas, modelos y launchers generados no
se publican (contrato "Propiedad del runtime Windows" en
`docs/spec/00-project-spec.md`).

## Desactivado por defecto

Nada aquí corre solo: `stage-selected.mjs` sin `--apply` solo valida (no
escribe), y `publish-selected.mjs` exige `--apply` o `--rollback` explícitos.
No hay tarea programada, cron ni hook que los invoque; agregar uno exige
decisión y autorización separadas (el merge no despliega).

## Pipeline

```text
build-selection.mjs <checkout-fuente> <selection.json>
stage-selected.mjs  <selection.json> <fuente> <staging> --apply
publish-selected.mjs <selection.json> <staging> <runtime> <transacción> --apply
publish-selected.mjs <selection.json> <staging> <runtime> <transacción> --rollback
```

1. **Manifiesto** (`{version: 1, policyVersion: 1, files: [{path, sha256}]}`):
   allowlist positiva versionada (`selection-policy.mjs`) + denylist cerrada
   por categoría. Solo archivos trackeados por git del checkout fuente.
2. **Staging** fuera del runtime vivo, con validación de set exacto y hashes
   antes de publicar. Sin borrados recursivos: un resto se reporta, no se
   limpia solo.
3. **Publicación** por archivo: temporal de nombre impredecible creado con
   O_EXCL (nunca sigue symlinks), rechazo de symlinks en staging y destino,
   confinamiento dentro del runtime, journal + fsync antes de cada reemplazo,
   y read-back del SHA instalado. Respaldo previo de cada reemplazo.
4. **Rollback** por archivo desde el journal + respaldos de la transacción.

## Política de ediciones vivas pendientes

Si el archivo vivo difiere tanto de lo último instalado (registro
`.ledger/sync-seguro-installed.json` del runtime) como de lo staged, NO se
sobrescribe: se imprime `SKIPPED live-edit <ruta>` y se sigue con el resto.
El operador resuelve (acepta lo staged publicando de nuevo tras conciliar, o
conserva lo vivo). Sin registro previo no hay "último instalado": se publica
con respaldo previo, reversible por `--rollback`.

## Interrupciones e idempotencia

Re-ejecutable tras kill con la misma transacción: lo publicado se salta, lo
pendiente se reintenta, lo inconsistente aborta. Segundo ciclo sin cambios =
cero escrituras. Una transacción previa distinta aborta (`prior transaction
pending`) en vez de mezclarse.

## Un solo dueño del watchdog y de los avisos (U1)

- Liveness del gateway: `gateway-watchdog.ps1` (raíz). Único vigilante
  activo: puerto + proceso wedged, reinicio por tarea programada, log local.
- `scripts/sync-repos.ps1`: OBSOLETO desde U1. Hacía `git add -A` dentro del
  estado vivo, prohibido por el contrato. Se conserva por historia; ningún
  camino activo lo invoca.
- `scripts/restart-openclaw-gateway.ps1`: herramienta MANUAL de reinicio, no
  watchdog (no vigila ni está programado).
- Este sync NO envía avisos (sin Telegram, sin red): reporta en stdout y
  journal. No se agregan emisores.

## Reversión

`--rollback` con la misma transacción restaura los bytes previos por archivo
y revierte el registro de instalados. Si el vivo cambió después de publicar,
el rollback se niega antes de tocar nada.
