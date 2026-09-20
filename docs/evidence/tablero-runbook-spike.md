# Spike 7.0 — SDK instalado y autorización (solo lectura)

Fecha de medición: 2026-09-17. Medidor: lead Fase 7. Gateway OpenClaw 2026.9.3 en C:\Users\ehven (.openclaw desplegado).

Método: un turno de solo lectura a main por función, con el `Select-String` de la lista cerrada del runbook (`docs/runbooks/autopilot-fase7.md`), una función por turno. Nota medida: `Select-String ... -Recurse` no existe en el PowerShell del gateway (ParameterBindingException); se usó `Get-ChildItem -Recurse -File | Select-String`, misma semántica.

## registerGatewayMethod

Comando:

```
Get-ChildItem 'C:\Users\ehven\AppData\Roaming\npm\node_modules\openclaw\dist' -Recurse -File | Select-String -Pattern 'registerGatewayMethod' | Select-Object -First 3 Path,LineNumber
```

Salida (recortada):

```
agent-harness-runtime-BwRgV0uy.d.ts:14356
agent-harness-runtime-DaJ4mxKg.d.ts:18379
cli-backend.types-BIb149tl.d.ts:19519
```

veredicto registerGatewayMethod: presente

## registerControlUiDescriptor

Comando: el mismo de arriba, con `-Pattern 'registerControlUiDescriptor'`.

Salida (recortada):

```
agent-harness-runtime-BwRgV0uy.d.ts:14274,14465,14467
```

veredicto registerControlUiDescriptor: presente

## registerHttpRoute

Comando: el mismo de arriba, con `-Pattern 'registerHttpRoute'`.

Salida (recortada):

```
agent-harness-runtime-BwRgV0uy.d.ts:14341
agent-harness-runtime-DaJ4mxKg.d.ts:18364
cli-backend.types-BIb149tl.d.ts:19504
```

veredicto registerHttpRoute: presente

## backupResources

Comando: el mismo de arriba, con `-Pattern 'backupResources'`.

Salida (recortada):

```
backup-archive-path-policy-DTr_0U9I.mjs:81,90
health-tuyyTTVY.d.ts:6707
```

veredicto backupResources: presente

## stateDir

Comando: el mismo de arriba, con `-Pattern 'stateDir'`.

Salida (recortada):

```
agent-exec-B7Xq9Gme.mjs:259,262,266
```

veredicto stateDir: presente

## dataDir

Comando: el mismo de arriba, con `-Pattern 'dataDir'`.

Salida (recortada):

```
agent-bundle-mcp-runtime-config-CZ1CMGrU.mjs:17,59,65
```

veredicto dataDir: presente

## Directorio de estado (muestra summa-gate)

Comando:

```
Test-Path C:\Users\ehven\.openclaw\summa-gate\state -PathType Container
```

Salida: `True`. Contiene `agent_*.json` (p. ej. `agent_main_main.json`).

Ruta: `C:\Users\ehven\.openclaw\summa-gate\state` — **dentro del clon** (el sync commitea con `add -A`).

## Sondas Mac

Comandos:

```
~/.openclaw/bin/openclaw gateway call status
~/.openclaw/bin/openclaw gateway call runbook.progress.get --params '{"fase":"6"}'
curl -s -o /dev/null -w '%{http_code}' http://100.80.179.76:18789/__openclaw__/a2ui/
```

Salidas: `status` responde (`runtimeVersion 2026.9.3`); `runbook.progress.get` falla por método desconocido, no por auth (`Gateway call failed: unknown method: runbook.progress.get`); el `curl` sin credencial devuelve `401`.

## Decisiones

1. `registerControlUiDescriptor` presente → 7.4 se entrega CON pestaña (`path:"/runbook/tablero/6"`).
2. Estado dentro del clon → 7.4 usa `configSchema.stateDir` con default fuera del clon: `C:\Users\ehven\.openclaw-state\tablero-runbook`; `.gitignore` cubre `.jsonl`/`.log` sin ruta absoluta.
