# B22, fase 0: recibo de las mediciones

Borrador de `docs/evidence/agent-work/B22-fase0.md`. Es la evidencia de la versión de opencode que certifica la ruta `run-per-task` (`hostAdapterRoute` en `coverage.json`).

```
medido:    2026-10-13, entre las 00:28 y las 00:36 UTC
máquina:   MacBook de David, macOS 26.7 arm64, usuario dn
opencode:  /opt/homebrew/bin/opencode --version -> 1.18.35
modelo:    zai-coding-plan/glm-5.3-flash
G:         bff085d704cba752161fc9ab2f8bf253106b79cc (lo usó M5)
scripts:   ~/.local/state/encargos-loop/B22/fase0/medir-run.sh
           sha256 87806b47…db93967b en las pasadas 002825Z y 002916Z (antes del arreglo de PWD)
           sha256 a8132fde…6f5633874 en la pasada 003422Z (con PWD fijado)
crudos:    ~/.local/state/encargos-loop/B22/fase0/resultados-20261013T002825Z/, …T002916Z/ y …T003422Z/
```

En las salidas, `<T>` es `/private/var/folders/hp/sc_3c6qs7nvdswl_x3w5sdbr0000gn/T` y `<fase0>` es `/Users/dn/.local/state/encargos-loop/B22/fase0`. Las rutas completas están en el `comando.txt` de cada corrida. Las líneas del flujo se cortan con `[…]`.

Todas las corridas comparten esto: stdin en `/dev/null`, sin `--auto`, `OPENCODE_DISABLE_AUTOUPDATE=1`, y un `OPENCODE_CONFIG_CONTENT` con las tres llaves de `opencode_env`:

```
{"permission":{"external_directory":{"<carpeta permitida>/**":"allow"}},"enabled_providers":["zai-coding-plan"],"small_model":"zai-coding-plan/glm-5.3-flash"}
```

## Resumen

| Medición | Veredicto | Lo que fija para el diseño |
|---|---|---|
| M1 | pasa | `opencode run --format json` termina sola, sin diálogo. No hace falta la sesión con pantalla. |
| M2 | pasa | Un permiso "ask" no se aprueba solo. El archivo de fuera no se creó. |
| M6 | pasa: "rechaza y termina" | No existe evento de permiso ni espera. opencode avisa por stderr, deja el `tool_use` en error y el proceso sale con 0. |
| M3a | pasa | Un modelo que no existe sale con 1 en menos de un segundo. El flujo solo dice "Unexpected server error". |
| M3b | pasa | `enabled_providers` impide llamar a un proveedor que no es el del encargo. La causa sale en los logs. |
| M3c | pasa | Con `small_model`, todas las llamadas van al proveedor del encargo. |
| M5 | no pasa, y después pasa | La primera corrida destapó que opencode toma su carpeta de `PWD`. Con `PWD` fijado, acuse y resultado llegan y el spool queda `acknowledged`. |
| PWD | medido | El lanzador tiene que fijar `PWD` igual a la carpeta del encargo. |
| M4 | sin medir | Espera el comando de administrador que crea el grupo `agent-work-enc1`. David ya lo aceptó. |

Un límite de este recibo. M1, M2, M6 y M3 corrieron con el script de antes del arreglo, así que sus sesiones abrieron en `<fase0>` y no en el repo temporal (ver "PWD"). Sus veredictos no dependen de eso: M1 y M3 no miran la carpeta, y el archivo de M2 estaba fuera de las dos carpetas. Antes de publicar el recibo conviene repetir M2 con el script ya arreglado (`./medir-run.sh --solo m2`), para que el rechazo quede medido con la sesión en el repo.

## M1

Pregunta. ¿`opencode run -m zai-coding-plan/glm-5.3-flash --format json "di hola" </dev/null >eventos.jsonl` termina sola y sin diálogo?

Comando (`resultados-20261013T002825Z/m1/comando.txt`):

```
cd <T>/b22-fase0.dSgcxepA/repo && env OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_CONFIG_CONTENT='…' /opt/homebrew/bin/opencode run -m zai-coding-plan/glm-5.3-flash --format json 'di hola' </dev/null >…/m1/eventos.jsonl 2>…/m1/stderr.txt
```

Salida literal. `eventos.jsonl`, 3 líneas:

```
1: {"type":"step_start","timestamp":1791851313467,"sessionID":"ses_ecd56e1d8ffeUUA25oYMbKtqhd","part":{"id":"prt_132a9392c001zxL2eH18uFp78C","messageID":"msg_132a91efa00137umY9LJOc6hDB","sessionID":"ses_ecd56e1d8ffeUUA25oYMbKtqhd","type":"step-start"}}
2: {"type":"text","timestamp":1791851313467,"sessionID":"ses_ecd56e1d8ffeUUA25oYMbKtqhd","part":{"id":"prt_132a93934001VB5o0hjTc29ugv",[…]"type":"text","text":"Hola. ¿En qué te ayudo?",[…]
3: {"type":"step_finish","timestamp":1791851313467,"sessionID":"ses_ecd56e1d8ffeUUA25oYMbKtqhd","part":{"id":"prt_132a93937001BOrMdqbNdbcZ72","reason":"stop",[…]
```

`stderr.txt`: vacío. `cierre.json`: salió con 0 a los 7,48 s; primera línea del flujo a los 7,48 s; 0 procesos vivos al cierre.

Veredicto: **pasa**. Sale con 0, sin "Update Available" en el flujo ni en stderr.

## M2 y M6

Pregunta de M2. Sin `--auto` y con stdin en `/dev/null`, ¿un pedido de escribir un archivo de fuera se queda sin escribir?

Pregunta de M6. ¿Qué trae el flujo cuando opencode topa con un permiso "ask", y qué hace el proceso: rechaza, espera o aprueba?

Comando (`resultados-20261013T002825Z/m2-m6/comando.txt`):

```
cd <T>/b22-fase0.dSgcxepA/repo && env OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_CONFIG_CONTENT='…' /opt/homebrew/bin/opencode run -m zai-coding-plan/glm-5.3-flash --format json 'Crea el archivo <T>/b22-fase0-fuera.hsQaz0TJ/b22-m2-fuera.txt con la palabra hola.' </dev/null >…/m2-m6/eventos.jsonl 2>…/m2-m6/stderr.txt
```

Salida literal. `stderr.txt`, una línea, con códigos de color delante del signo de admiración:

```
! permission requested: external_directory (<T>/b22-fase0-fuera.hsQaz0TJ/*); auto-rejecting
```

`eventos.jsonl`, 3 líneas: `step_start`, `tool_use` y `step_finish` con `"reason":"tool-calls"`. Lo que importa del `tool_use`:

```
{"type":"tool_use", … "part":{"type":"tool","tool":"bash","callID":"call_a1c020ba1d06414383f2a411",
  "state":{"status":"error",
           "input":{"command":"mkdir -p <T>/b22-fase0-fuera.hsQaz0TJ"},
           "error":"The user rejected permission to use this specific tool call.", "time":{…}}, …}}
```

`cierre.json`: salió con 0 a los 5,89 s; primera línea del flujo a los 3,55 s; 0 procesos vivos al cierre; ninguna señal enviada. `ls-fuera.txt`: la carpeta de fuera quedó vacía.

Veredicto de M2: **pasa**. El archivo no existe al terminar el proceso.

Veredicto de M6: **pasa**, con la clasificación "rechaza y termina". Después del rechazo no hay ningún evento más del modelo. Los eventos llegan al archivo hasta 0,07 s después de su marca de tiempo, con el proceso vivo.

Lo que fija. No existe un evento de permiso propio en el flujo. El permiso y su patrón solo salen en stderr. El flujo solo dice qué herramienta quedó en error. El código de salida es 0, así que el código no distingue un encargo terminado de uno cortado por un permiso.

## M3a

Pregunta. ¿`-m zai-coding-plan/no-existe` sale distinto de 0 en menos de 30 s?

Comando: el de M1 con `-m zai-coding-plan/no-existe`.

Salida literal. `eventos.jsonl`, una línea:

```
{"type":"error","timestamp":1791851320346,"sessionID":"ses_ecd56aca3ffe6Tqp1GoBVerLQb","error":{"name":"UnknownError","data":{"message":"Unexpected server error. Check server logs for details.","ref":"err_f9d37afd"}}}
```

`stderr.txt`: vacío. `cierre.json`: salió con 1 a los 0,65 s.

Veredicto: **pasa**.

Lo que fija. El evento `error` del flujo no dice la causa. Sin logs, el host solo podría repetir "Unexpected server error".

## M3b

Pregunta. ¿`enabled_providers: ["zai-coding-plan"]` impide `-m zai/glm-5.3`?

Comando: el de M1 con `-m zai/glm-5.3 --format json --print-logs --log-level INFO 'responde solo: ok'`.

Salida literal. `eventos.jsonl`, una línea de tipo `error` igual a la de M3a, con `"ref":"err_c749d686"`. `stderr.txt`, 21 líneas. Las que importan:

```
18: timestamp=2026-10-13T00:28:41.175Z level=ERROR run=b35d3b06 message="share subscriber failed" type=message.updated cause="Cause([Fail(ProviderModelNotFoundError: Model not found: zai/glm-5.3. Did you mean: glm-5.3, glm-5.3-flash, glm-5.3-flashx?)])"
20: timestamp=2026-10-13T00:28:41.182Z level=ERROR run=b35d3b06 message=failed ref=err_c749d686 error="ProviderModelNotFoundError: Model not found: zai/glm-5.3. Did you mean: glm-5.3, glm-5.3-flash, glm-5.3-flashx?" […]
```

`cierre.json`: salió con 1 a los 0,75 s. Ninguna línea `message=stream` en los logs.

Veredicto: **pasa**. Salió sin ningún evento del modelo y sin llamar a `zai`.

Lo que fija. Con `--print-logs --log-level INFO`, la causa real sale en una línea `level=ERROR` de stderr.

## M3c

Pregunta. Con `small_model` igual al modelo del encargo, ¿alguna llamada va a otro proveedor?

Comando: el de M1 con `--format json --print-logs --log-level INFO`, sin `--title`, para que opencode genere el título con el modelo pequeño.

Salida literal. `stderr.txt`, 33 líneas. Las dos líneas `message=stream`:

```
22: timestamp=2026-10-13T00:28:42.184Z level=INFO run=4a0a032c message=stream providerID=zai-coding-plan modelID=glm-5.3-flash session.id=ses_ecd56a597ffe6GHqp405Otldki small=true agent=title mode=primary
29: timestamp=2026-10-13T00:28:42.563Z level=INFO run=4a0a032c message=stream providerID=zai-coding-plan modelID=glm-5.3-flash session.id=ses_ecd56a597ffe6GHqp405Otldki small=false agent=build mode=primary
```

Evidencia del script: "4 llamadas al modelo en los logs, todas de zai-coding-plan; modelo de las llamadas con small=true: zai-coding-plan/glm-5.3-flash; el flujo de m1 y m3c nombra: ningún proveedor". `cierre.json`: salió con 0 a los 3,21 s.

Veredicto: **pasa**.

Lo que fija. Los logs traen el proveedor de cada llamada en `providerID=`. El host puede anotar qué proveedores llamó cada encargo.

## M5

Pregunta. ¿El modelo por omisión cumple acuse y resultado cuando la línea llega como argumento y los archivos viven en `runs/<op>/`?

M5 no es el e2e del repo. Arma `runs/<op>/` con `cli_protocol` y el spool de G, pasa la línea de `TmuxTransport.deliver` como argumento y juzga con `Host.take_acceptance`, `Host.collect` y `Host.flush`. R es un doble que devuelve el recibo.

### Primera corrida, 00:29:16Z: no pasa

Comando (`resultados-20261013T002916Z/m5/comando.txt`). El lanzador era un `Popen` de Python con `cwd=<T>/b22-fase0.NwbniHNs/repo` que heredaba `PWD=<fase0>`:

```
/opt/homebrew/bin/opencode run -m zai-coding-plan/glm-5.3-flash --format json --title b22-fase0-m5-afc3d62f 'Open assignment JSON at <T>/b22-fase0.NwbniHNs/spool/runs/11ffc19d…17428772/assignment.json. First write agent-work.accept.v1 atomically to acceptRef with schema, hostId, taskId, generation, instanceId, claimId and capability copied from the assignment. Then follow briefRef and write agent-work.result.v1 atomically to resultRef.'
```

Salida literal. `stderr.txt`:

```
! permission requested: external_directory (<T>/b22-fase0.NwbniHNs/repo/*); auto-rejecting
```

`eventos.jsonl`, 18 líneas. El último `tool_use`, línea 17, es un `bash` que escribe `<T>/b22-fase0.NwbniHNs/repo/b22-m5.txt` y queda con `"status":"error"` y `"error":"The user rejected permission to use this specific tool call."`. `cierre.json`: `accept.json` apareció a los 13,51 s, `result.json` no apareció, salió con 0 a los 25,37 s.

Log de opencode (`~/.local/share/opencode/log/opencode.log`, línea 239874):

```
timestamp=2026-10-13T00:29:16.892Z level=INFO run=8e0bdab8 message=created id=ses_ecd561d24ffeR8q1tzafqbyklc slug=swift-panda version=1.18.35 projectID=global directory=/Users/dn/.local/state/encargos-loop/B22/fase0 path=Users/dn/.local/state/encargos-loop/B22/fase0 […]
```

Veredicto: **no pasa**. El spool quedó en `delivered`. opencode negó escribir dentro del propio repo del encargo, porque su sesión estaba en `<fase0>`.

### Segunda corrida, 00:34:22Z, con `PWD` fijado: pasa

El único cambio del script es `env=dict(os.environ, PWD=str(a.cwd))` en el `Popen`.

Salida literal. `stderr.txt`: vacío. `eventos.jsonl`, 26 líneas: 7 `step_start`, 7 `step_finish`, 6 `text` y 6 `tool_use`, todos con `"status":"completed"`. `cierre.json`: `accept.json` a los 16,49 s, `result.json` a los 41,11 s, salió con 0 a los 53,8 s, 0 procesos vivos al cierre.

`accept.json`:

```
{"schema": "agent-work.accept.v1", "hostId": "mac-local", "taskId": "b22-fase0-m5-4a109296", "generation": 1, "instanceId": "b22-fase0", "claimId": "b22-fase0-27a819a3", "capability": "<quitada>"}
```

Log de opencode, línea 240508:

```
timestamp=2026-10-13T00:34:23.289Z level=INFO run=afa38d3e message=created id=ses_ecd517046ffe3pcIW1wjoKP1CQ slug=quiet-wizard version=1.18.35 projectID=19fe1fc2ab4dd5aa2a5481f4e48919c35afc3f21 directory=<T>/b22-fase0.TAt6Qiyr/repo path="" […]
```

Veredicto: **pasa**. `take_acceptance=True`, `collect` devolvió un resultado válido y el spool quedó en `acknowledged`.

## PWD: de dónde toma opencode su carpeta

Hallazgo. opencode 1.18.35 abre la sesión en la carpeta que dice la variable de entorno `PWD`, no en el cwd real del proceso.

Experimento de tres corridas, 00:33:36Z a 00:33:51Z, con un lanzador de Python que fija `cwd=<T>/tmp.utiT7YQMAt/repo`. Los comandos exactos no quedaron guardados. Lo que queda son las líneas del log de opencode (`opencode.log`, 240407 a 240476) y la entrada "B22 fase 0, M5" de `~/.local/state/encargos-loop/estado.md`.

Corrida A, `PWD` heredado de otra carpeta (`<S>` es la carpeta temporal de la sesión de Claude):

```
240407: … run=e15102af message="creating instance" directory=<T>/tmp.utiT7YQMAt/repo
240416: … run=e15102af message="creating instance" directory=<S>
240422: … run=e15102af message=created id=ses_ecd522735ffeBiXV03JoVQ0N2y slug=clever-comet version=1.18.35 projectID=global directory=<S> […]
```

Corrida B, `PWD` igual al repo:

```
240444: … run=79db3a9f message=created id=ses_ecd52180fffebCUZycz2hNvlT2 slug=nimble-engine version=1.18.35 projectID=a0ad8de6eb333aba03145852bf122ae34e042275 directory=<T>/tmp.utiT7YQMAt/repo path="" […]
        … run=79db3a9f message=evaluated permission=bash pattern="touch <T>/tmp.utiT7YQMAt/repo/b-pwd-repo.txt" action.permission=* action.action=allow action.pattern=*
```

Corrida C, sin `PWD` en el entorno:

```
240476: … run=48831acc message=created id=ses_ecd51fe46ffeL3ber5WkVFbB0t slug=cosmic-wizard version=1.18.35 projectID=a0ad8de6eb333aba03145852bf122ae34e042275 directory=<T>/tmp.utiT7YQMAt/repo path="" […]
        … run=48831acc message=evaluated permission=bash pattern="touch <T>/tmp.utiT7YQMAt/repo/c-sin-pwd.txt" action.permission=* action.action=allow action.pattern=*
```

La misma huella está en los recibos de M3, que corrieron con `--print-logs` antes del arreglo. `resultados-20261013T002825Z/m3c/stderr.txt`:

```
1:  … message="creating instance" directory=<T>/b22-fase0.dSgcxepA/repo
10: … message="creating instance" directory=<fase0>
16: … message=created id=ses_ecd56a597ffe6GHqp405Otldki slug=silent-falcon version=1.18.35 projectID=global directory=<fase0> […]
```

Veredicto: **medido**. Con `PWD` heredado la sesión abre en la otra carpeta, con `projectID=global`. Con `PWD` igual al repo, o sin `PWD`, abre en el repo.

Lo que fija. Es una guarda de seguridad y de corrección. La carpeta que opencode le abre al modelo depende de `PWD`. El lanzador del host fija `PWD` igual a la carpeta validada del encargo, en `opencode_env`. Con `--print-logs`, la línea `message=created … directory=` queda en stderr y el host puede comprobar en cada corrida dónde abrió la sesión.

Lo que no se midió. Qué hace `--dir`, que existe en la ayuda de `run`. El diseño no depende de él.

## M4

Sin medir. `medir-grupo.sh` (sha256 `bfa3fcfc…3770cd70`) sale con código 3 mientras el grupo `agent-work-enc1` no exista. La preparación está en `fases.md` y la corre David, que ya aceptó hacerlo ("1 acepto", P10866). Hay una medición previa a favor de la segunda mitad de M4: `mediciones/m8-grupo-de-archivos-nuevos.sh`, bajo `newgrp admin`, deja archivos, carpetas y objetos de git en `staff`.

## Lo que falta para cerrar este recibo

1. M4, cuando David cree el grupo.
2. Repetir M2 con el script arreglado, para que la sesión esté en el repo.
3. Repetir M5 con `--print-logs --log-level INFO`, que es como va a lanzar el host. M5 pasó sin esas dos banderas.
4. Guardar los tres comandos del experimento de `PWD` si se repite.
