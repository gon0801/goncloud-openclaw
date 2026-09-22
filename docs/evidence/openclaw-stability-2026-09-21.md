# Reparacion de estabilidad de OpenClaw, 2026-09-21

## Sintomas

- El gateway conservaba el puerto 18789 en escucha, pero dejaba de responder.
- Mac, Telegram e iPhone se desconectaban a la vez.
- La actualizacion desde 2026.9.3 fallaba antes de sustituir la instalacion.

## Causas confirmadas

1. El gateway retenia transacciones SQLite en el hilo principal. Los logs
   registraron esperas de hasta 17.48 segundos y preparaciones de runtime de
   45 a 74 segundos.
2. El watchdog declaraba al gateway colgado tras una sola espera HTTP de 10
   segundos. En el incidente de las 22:44:58 mato el proceso durante una pausa
   recuperable.
3. Windows tenia dos tareas de inicio de sesion para el mismo node-host:
   `OpenClaw Node` y `OpenClaw CUA Node`. La copia manual competia por el mismo
   estado SQLite y termino con `SQLite source did not stabilize after 10
   read-only inspection attempts`.
4. `GoncloudRepoSync` ejecuto `git reset --hard` a las 23:11:24 y revirtio
   cambios operativos que no estaban versionados.
5. El launcher anterior impedia que el actualizador resolviera el propietario
   de la instalacion. El preflight devolvia `managed-service-preflight`.

## Cambios aplicados en Windows

- OpenClaw quedo actualizado a `2026.9.5 (ec9c1a1)`.
- Doctor migro las nueve bases de agentes y reparo ocho registros de rutas.
- Los siete plugins oficiales pendientes quedaron en 2026.9.5.
- Las variables del tablero pasaron al `.env` soportado por OpenClaw. Los
  launchers generados ya no contienen carga manual previa al comando.
- El timeout HTTP del watchdog quedo en 90 segundos y su limite de ejecucion
  en tres minutos.
- `OpenClaw CUA Node` quedo deshabilitada. `OpenClaw Node` es la unica tarea
  oficial habilitada para el node-host.
- `GoncloudRepoSync` queda deshabilitada hasta que este cambio llegue a
  `main`; reactivarla antes restauraria el timeout de 10 segundos.

## Verificacion

- `/startupz`: HTTP 200, `status=started`, version 2026.9.5.
- `/readyz` local y por Tailscale: HTTP 200.
- Doce sondeos consecutivos del gateway: `failures=0/12`.
- La prueba nueva fallo antes del cambio con:
  `gateway-watchdog.ps1 is missing: $httpTimeoutSec = 90`.
- Tras cambiar el timeout: `PASS test-gateway-watchdog`.
- La copia manual del node-host informa `Disabled`; la tarea oficial sigue
  habilitada.

## Riesgo restante

OpenClaw 2026.9.5 todavia registra esperas SQLite y degradacion temporal del
event loop durante corridas concurrentes. El cambio evita que el watchdog
convierta pausas menores de 90 segundos en apagones, pero no elimina la
contencion interna. El node-host de Windows no debe arrancarse durante esa
carga; la aplicacion de Mac ya proporciona un nodo conectado.
