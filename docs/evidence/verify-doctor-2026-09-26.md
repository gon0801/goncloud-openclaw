# Prueba: doctor de la skill verify, 2026-09-26

Pasada de mantenimiento. El doctor viejo tenía dos checks rotos por el entorno;
esta corrida midió el estado real del host y fijó los reemplazos.

## Hallazgos (todos por exec en el host gateway, vía turno a `main`)

1. `git -C C:\Users\ehven\.openclaw log -1 --format=%H` →
   `fatal: not a git repository`. `Test-Path C:\Users\ehven\.openclaw\.git` →
   `False`. El host no es un clon git: el plugin se despliega plano en
   `C:\Users\ehven\.openclaw\summa-gate\index.ts` (visto en `plugins list`).
2. `C:\Users\ehven\.openclaw\logs\` contiene solo `gateway-launch.log`,
   `gateway-restart.log`, `gateway-watchdog.log`. `sync-repos.log` no existe
   (`Test-Path` → `False`) porque `scripts/sync-repos.ps1` es OBSOLETO desde U1
   (`scripts/sync-seguro/README.md`): el deploy ahora es manual por manifiesto.
   La tarea `GoncloudRepoSync` quedó con LastRunTime 2026-09-21 23:10 EDT.
3. El reemplazo verificado: el ledger
   `C:\Users\ehven\.openclaw\.ledger\sync-seguro-installed.json` mapea cada
   path publicado a su sha256 canónico. Para `summa-gate/index.ts`:

   ```
   ledger:      c2cb888b8fa8b9326649fc8f7cb5fa513fb1902384d38cc0638c68aeffe7d71d
   origin/main: c2cb888b8fa8b9326649fc8f7cb5fa513fb1902384d38cc0638c68aeffe7d71d
                (git show origin/main:summa-gate/index.ts | shasum -a 256)
   ```

   Iguales: el gateway corre exactamente `origin/main` para ese archivo.
4. `openclaw plugins list` corre en vivo y muestra `summa-gate` enabled.

## Nota de quoting

`ForEach-Object { $_.Line }` llega al host como `{ .Line }`: el `$_` se pierde
en alguna capa entre el mensaje y PowerShell. Para pipelines, mejor
`Select-Object -ExpandProperty` o la salida por defecto de `Select-String`.
