# Diseño: la ruta de encargos se recertifica sola

**Estado:** decidido por David el 2026-10-17 ("va la 2, que se recertifique solo"), después de rechazar quitar el candado de versión ("tenemos que hacer que funcione con cualquier version de opencode, no tener que certificar eso es una estupidez nos estamos bloqueando a nosotros mismos"). Es un bloque propio, fuera de SUA-07.

## Problema

`Route.open_for` (`scripts/agent-work/sesion.py:181`) cierra la ruta cuando la versión del CLI no está en `coverage.json` `hostAdapterRoute.mac-local.<cli>.certifiedCliVersions`. Los dos CLI se actualizan solos. El 2026-10-17 las dos rutas estaban cerradas a la vez: opencode 1.19.3 contra 1.18.35 certificada, y claude 2.1.302 contra 2.1.301. `preparar` contestaba `ruta-no-certificada` y ningún loop podía encargar nada.

Recertificar a mano son cinco pasos (`docs/evidence/agent-work/T12-runbook.md`, "Recertificar una versión nueva de opencode"): relanzar el host con `--canario`, repetir las mediciones de `B22-fase0.md` con `~/.local/state/encargos-loop/B22/fase0/medir-run.sh`, mandar un canario por `main`, abrir un PR y relanzar el host. Ninguno necesita juicio humano. Todos esperan a una persona.

El candado no se quita: la ruta encierra al modelo en su carpeta por cómo se comporta el CLI (niega un permiso y termina, toma su carpeta de `PWD`, deja sus logs con cierta forma), y una versión nueva puede cambiar eso. Lo que cambia es quién lo vuelve a medir.

## Qué hace

Cuando el host ve una versión del CLI que no está medida, corre él mismo las mediciones y el banco. Con todo en verde, anota la versión y la ruta sigue. Con algo en rojo, la ruta queda cerrada y David recibe un aviso con la causa. Mientras mide, los encargos esperan en R; nadie recibe un rechazo.

## Forma

### El registro de versiones medidas

`~/.local/state/agent-work-host/versiones-medidas.json`:

```json
{"schema": "agent-work.cli-versions.v1",
 "routes": {"mac-local/opencode": {"1.19.3": {
   "estado": "verde", "medidoEn": "2026-10-17T23:40:00Z", "commit": "<sha del checkout del host>",
   "sondas": {"m1": "pasa", "m2": "pasa", "m3a": "pasa", "m3b": "pasa", "m3c": "pasa", "pwd": "pasa", "m7": "pasa"},
   "banco": "verde", "evidencia": "recertificacion/mac-local-opencode/1.19.3/",
   "digest": "<sha256 de la evidencia>", "intentos": 1, "aviso": {"enviado": true}}}}}
```

`estado` es `probando`, `verde`, `rojo` o `infraestructura`. Solo `verde` abre la ruta. Lo escribe solo `encargo.py recertificar`, con escritura atómica y bajo el mismo `_policy_lock` que usa `sucesion`.

`coverage.json` sigue siendo la fuente de lo certificado por PR. El registro suma versiones; nunca quita ni abre una ruta que `coverage.json` no tenga en `certified`. Una ruta `sandbox-tested-uncertified` o `absent` nunca se recertifica sola.

### La ruta une las dos fuentes

`Route.load(coverage, host_id, adapter_id, medidas=None)` suma a `certified_cli_versions` las versiones con `estado: verde` de `medidas`, solo si el estado de la ruta es `certified`. Una función nueva `cargar_ruta(checkout, state_root, host_id, adapter_id)` lee los dos archivos, y la usan los dos llamadores: `RunHost.plan` (`native_gateway.py:703`) y `preparar` (`encargo.py:272`). Un registro ilegible es un registro vacío: la ruta queda como la deja `coverage.json`.

### Las sondas viven en el repo

`scripts/agent-work/recertificar.py` porta de `medir-run.sh` las sondas que dependen de la versión: M1, M2/M6, M3a, M3b, M3c, PWD y M7. Corre cada una en un repo desechable de `mktemp`, con el ambiente real del host (`sesion.opencode_env`, que ya trae `"*": "deny"`) y su tope. M4 (frontera del grupo) no se repite: es del sistema operativo. M5 la cubre el banco. Cuesta unos 30 s de `zai-coding-plan/glm-5.3-flash`.

Para claude, las sondas son las de M-21, M-23 y M-24 (`SUA-04-mediciones.md`) en su forma de prueba.

### El ejecutor

`encargo.py recertificar [--ruta mac-local/opencode|mac-local/claude]` copia el esqueleto de `sucesion`:

1. Lee la versión del CLI. Si ya tiene entrada terminal (`verde` o `rojo`) en el registro, o está en `coverage.json`, sale con 0 sin hacer nada.
2. Si `_host_ocupado`, sale y lo intenta en la pasada siguiente.
3. Marca `probando` bajo el candado.
4. Corre las sondas. Si alguna falla, `rojo`.
5. Corre el banco: `test_agent_work_banco_e2e.py -k profiled_engineering` para opencode, y los tres casos de claude con `AGENT_WORK_BANCO_ADAPTER=claude`. Lo clasifica con `clasificar_banco`.
6. Escribe el resultado con su evidencia y su digest.
7. Avisa con `avisar.py`: verde como información ("La ruta de encargos ya trabaja con opencode 1.19.3"), rojo como alerta con la sonda que falló y la ruta de la evidencia, e infraestructura como alerta desde el primer intento, porque la ruta está cerrada mientras tanto.

`infraestructura` se reintenta en la pasada siguiente, hasta 3 veces. A la tercera queda `rojo` con esa causa.

### Quién lo dispara

El host, en su pasada. Ya lee la versión en cada pasada (`RunHost.catalog`, `native_gateway.py:599`). Si la versión del CLI de una ruta `certified` no está medida y no hay una recertificación viva, lanza `encargo.py recertificar --ruta <ruta>` como proceso aparte, con su log en `~/Library/Logs/goncloud/agent-work-recertificar.log`, y sigue. Un `flock` en `state_root/recertificar.lock` impide dos a la vez. No hace falta un launchd nuevo.

### Mientras mide, los encargos esperan

- **En el host.** Una compuerta antes del claim, como `_claim_rechazado_en` (`native_gateway.py:747`): con la ruta del adaptador en `probando`, el host no reclama tareas de ese adaptador. Esperan en R sin `launch-refused`.
- **En `preparar`.** Con la ruta en `probando`, contesta `ok: true` con `"espera": "recertificando"` y la frase "La ruta de encargos está midiendo opencode 1.19.3; el encargo sale en unos minutos". `main` registra la tarea igual.
- **Con `rojo`.** `preparar` contesta `ruta-roja` con la sonda que falló, y el host rechaza con `launch-refused` como hoy.

### El canario manual sigue existiendo

`--canario` y el procedimiento de T12 quedan para lo que el automático no cubre: una ruta nueva, o un `rojo` que alguien quiere forzar después de revisarlo. Un PR que agrega una versión a `coverage.json` sigue siendo válido y gana sobre el registro.

## Pruebas que deben discriminar

1. Versión nueva, sondas y banco verdes: la ruta se abre sin relanzar el host, y `preparar` contesta `ok`.
2. Una sonda roja: la ruta sigue cerrada, el registro dice `rojo` con esa sonda y se manda un aviso.
3. Mientras está en `probando`, el host no reclama tareas de ese adaptador y `preparar` contesta `espera: recertificando`.
4. Dos pasadas seguidas lanzan una sola recertificación (`flock`).
5. Una versión con entrada terminal no vuelve a medirse.
6. Una ruta `sandbox-tested-uncertified` no se recertifica sola, aunque el registro tenga un `verde` escrito a mano.
7. Un registro ilegible deja la ruta como la deja `coverage.json`.
8. `infraestructura` reintenta y a la tercera queda `rojo`.
9. El banco ocupado (`_host_ocupado`) pospone sin escribir nada.

Las pruebas que hoy fijan el rechazo (`test-agent-work-sesion.py:1511`, `test-agent-work-encargo.py:485`, `test-agent-work-modelos.py:699`, `test-agent-work-claude.py:339`) siguen valiendo para una versión sin medir y sin recertificación; se agregan las nuevas al lado.

## Plan

| Fila | Contenido | DoD |
| --- | --- | --- |
| R.1 | `cargar_ruta` y la unión del registro en `Route.load`; los dos llamadores la usan. | Pruebas 6 y 7; las cuatro pruebas actuales en verde. |
| R.2 | `recertificar.py` con las sondas de opencode y de claude, portadas de `medir-run.sh` y de M-21/M-23/M-24. | Cada sonda con su prueba sobre un doble del CLI que se porta bien y otro que se porta mal; una corrida real contra opencode 1.19.3 pegada en la evidencia. |
| R.3 | `encargo.py recertificar` con el esqueleto de `sucesion`, el registro y los avisos. | Pruebas 2, 5, 8 y 9 con el banco inyectado (`AGENT_WORK_SUCESION_BANCO`). |
| R.4 | El disparo desde la pasada del host y la compuerta antes del claim; `espera` y `ruta-roja` en `preparar`. | Pruebas 1, 3 y 4. |
| R.5 | En vivo: actualizar el checkout del host, relanzarlo una vez y dejar que recertifique opencode 1.19.3 y claude 2.1.302 solo. Runbook T12 al día. | El registro con las dos versiones en `verde`, los dos avisos recibidos y un `preparar` real que contesta `ok`. |

## Riesgos aceptados

- **El mismo usuario puede escribir el registro.** El slot corre con la cuenta de David y su shell no está confinado (`coverage.json`, `directoryGuard.limitation`), así que un encargo podría escribir un `verde` falso. Hoy ya puede escribir el checkout del host. El digest ata cada `verde` a su evidencia; no es una firma.
- **El canario real por `main` no se repite por versión.** El banco usa un R de juguete. Lo que el canario real probaba es la integración R y Mini, que no depende de la versión del CLI.
- **Cuota.** Cada versión nueva cuesta unos 30 s de sondas y el banco: unos 3 a 4 minutos de GLM para opencode y del cupo Max para claude. claude se actualiza seguido.
- **Un R viejo da infraestructura.** El banco exige un R con buildstamp de HEAD. Por eso infraestructura avisa desde el primer intento.
