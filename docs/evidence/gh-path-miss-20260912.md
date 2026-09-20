# gh PATH miss — sanitized evidence (2026-09-12)

Date: 2026-09-12
Runtime: OpenClaw 2026.9.4 (installed plugin boundary)

Symbolic facts (machine-checkable):

- `tool=exec`
- `incident=path_miss:gh_cli`
- `known_location=C:\Users\ehven\.openclaw\tools\bin\gh.exe`
- `plugin_origin=config`
- `schedule_result=undefined`

## Context

- [HECHO] Host `Windows`, runtime OpenClaw `2026.9.4`, plugin `summa-gate` instalado como `plugin_origin=config` (no bundled).
- [HECHO] El ejecutable `gh` estaba instalado en `known_location=C:\Users\ehven\.openclaw\tools\bin\gh.exe`, fuera del `PATH` del runtime del agente.
- [HECHO] Existian fuentes de autenticacion configuradas en el host (`[removed]`); el detalle de valores, tiendas y variables queda removido.
- [DATO REMOVIDO] Nombres de usuario adicionales, valores de tokens, variables de entorno completas, comandos verbatim y salida cruda: `[removed]`.

## Observed failure

- [HECHO] `tool=exec`: un primer intento de invocar `gh` por nombre corto fallo con una firma de comando-no-encontrado / resolucion de ruta (firma estructurada del incidente `incident=path_miss:gh_cli`).
- [HECHO] El fallo describe UNICAMENTE que esa ruta de invocacion (`gh` via `PATH` actual) no resolvio. No describe el estado de otras rutas, del ejecutable conocido, ni de la autenticacion.
- [DATO REMOVIDO] Texto exacto del error, comando exacto, `stderr`/`stdout` crudos, `exitCode` crudo: `[removed]`.

## Incorrect conclusion

- [INFERENCIA INCORRECTA] Tras el fallo observado, el agente concluyo a nivel de tarea que la capacidad no existia / no estaba disponible / no tenia acceso (forma: "GitHub CLI y credenciales no existen").
- [HECHO] Esa conclusion es mas amplia que la evidencia: un fallo de resolucion `PATH` no implica inexistencia del binario, ni falta de credenciales, ni indisponibilidad de la capacidad.
- [DATO REMOVIDO] Redaccion literal de la respuesta final del agente y prompt original: `[removed]` (no se reproduce el prompt; solo la clase de conclusion).

## Independent discovery

- [HECHO] Una inspeccion posterior independiente del inventario de ejecutables encontro el binario en `known_location=C:\Users\ehven\.openclaw\tools\bin\gh.exe`.
- [HECHO] La invocacion por ruta absoluta con un probe de solo lectura (`--version`) es el paso de descubrimiento que el fallo inicial no habia intentado.
- [HECHO] La verificacion de estado de auth/capacidad debe hacerse por presencia (`SET`/`UNSET`, `FOUND`/`NOT_FOUND`), sin imprimir valores.
- Fuentes independientes que permiten re-derivar el hallazgo (ninguna es el diseño de este cambio):
  - `agents/main/agent/workshop-skills/git-commit-push/SKILL.md:23` — registro operativo versionado: `gh` vive en `C:\Users\ehven\.openclaw\tools\bin\gh.exe`, autenticado por keyring como el owner. Prueba que el binario y la credencial existian.
  - `agents/main/agent/workshop-skills/gateway-cli-setup/SKILL.md:16` — layout de instalacion: el zip de `gh` se extrae directo en `<tools-dir>\bin\gh.exe`. Explica por que un fallo de `PATH` no implica inexistencia.
  - Cualquier revisor puede re-derivar "fallo PATH != capacidad inexistente" combinando esas dos skills sin acceder al transcript original. El diseño (`docs/superpowers/specs/2026-09-12-structural-investigation-guard-design.md`, Problem) solo se cita como referencia cruzada, no como prueba.

## SDK boundary

- [HECHO] `plugin_origin=config`: `summa-gate` es un plugin instalado/configurado, no bundled.
- [HECHO] `schedule_result=undefined`: en OpenClaw 2026.9.4, `api.session.workflow.scheduleSessionTurn(...)` solo funciona para plugins bundled; para un plugin instalado retorna `undefined`. Por eso V1 no cancela respuestas ni fabrica continuaciones cross-run.
- [HECHO] `resolve_exec_env` descarta `PATH` (el host lo elimina); la guia debe descubrir `gh.exe` y usarlo por ruta absoluta. Cualquier `tools.exec.pathPrepend` global es una decision operativa separada, fuera de este bloque.
- [HECHO] El middleware soportado separa evento y contexto: el evento trae `toolCallId/toolName/args/isError/result` y el `runId` vive solo en el contexto (`AgentToolResultMiddlewareEvent`, `AgentToolResultMiddlewareContext`); el estado por run usa `api.runContext` (`set/get/clearRunContext` con `{runId, namespace}`).
- Fuente verificable en el host: SDK instalado `node_modules/openclaw/dist/agent-harness-runtime-CZb40n5o.d.ts` (middleware: lineas 14253-14277; runContext: lineas 14987-14994; scheduler: lineas 14951-14967).

## Sanitization

- Este artefacto NO contiene: prompt original, comandos verbatim, argumentos completos, salida cruda de herramientas, rutas dinamicas mas alla de la ruta fija conocida, variables de entorno, tokens, credenciales, material de claves, ni hashes de valores sensibles.
- Todo valor sensible fue reemplazado por `[removed]`. Solo `ehven` permanece como identificador ya presente en la ruta fija aprobada por el plan.
- Verificacion:
  - buscar los cinco hechos simbolicos con `rg` → cinco hechos presentes.
  - buscar firmas de secretos con `rg` → sin coincidencias.
