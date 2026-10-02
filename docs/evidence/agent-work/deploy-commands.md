# Comandos de despliegue: evidencia de preparación

Fecha: 2026-10-01. Alcance: worktree G `feat/agent-work-b1`, solo dobles y HOME temporal. No hay comandos productivos validados ni autorización de despliegue.

| Comando ensayado | Salida esperada | Duración máxima | Ante fallo |
| --- | --- | --- | --- |
| `bash scripts/tests/test-agent-work-cutover.sh` | `Ran 6 tests`, `OK` | 30 s | Conservar estado de ensayo y reparar el bloqueo; no habilitar admisión. |
| `bash scripts/tests/test-instalar-mac.sh` | `OK test-instalar-mac` | 30 s | Corregir el archivo o la verificación de blob; no instalar en HOME real. |

T0 registró en `runtime-map.json` `pnpm install --frozen-lockfile`, `pnpm build`, `pnpm test` y `pnpm openclaw --profile agent-work-isolated --help` para el checkout fuente. Son comandos de fuente o perfil aislado; ninguno equivale a instalar el runtime nativo de T11. Falta comprobar el comando de instalación y reversa contra el paquete final de B4. No usar un publicador de plugins como sustituto.

`artifact-manifest.json` se deja sin crear hasta disponer de SHA y hash del paquete final. Los manifiestos de la prueba son temporales y no certifican un artefacto distribuible. La configuración productiva sigue deshabilitada en `limits.json`.
