# SUA-06, recibo del bloque: seguimiento y panel

Bloque SUA-06 del
[plan](../../superpowers/plans/2026-10-05-sistema-agentes-unificado.md) (líneas 803-832), hecho según su
[diseño](../../superpowers/specs/2026-10-16-sua-06-seguimiento-y-panel-design.md). El ensayo de
LobsterBoard (M-26) vive en [SUA-06-lobsterboard.md](SUA-06-lobsterboard.md). R es el checkout de
integración de OpenClaw; su rama del bloque es `feat/agent-work-integration` en
`~/dev/openclaw-agent-work-integration` (`7615b0ae`, respaldada y en la Mini). G es este repo.

## Qué entregó

- **El derivador (P1).** `proyeccion.py derivar` lleva el snapshot de una raíz (`managedTasks.root.read`) a `sistema-agentes.proyeccion.v1`. Separa declarado, observado y aceptado: sin criterios da `null` y nunca 0, y una tarea viva, un merge o un `LISTO` no suben `accepted`. Cada unidad trae su fila con ejecutor, host, error del último incidente y `nextCheckAt`, siempre definido. Ids y textos pasan por una allowlist y por el filtro de secretos. Toda salida de los fixtures pasa `contrato.validar`. `leer` y `listar` hacen lo mismo contra el gateway.
- **La lista de raíces en R (P0).** `managedTasks.root.list` (`operator.admin`) devuelve `{roots: [{rootId, state, openedAt}]}` en orden estable; `{all: true}` incluye las cerradas. Las filas de `managedTasks` del catálogo de métodos pasaron a `managed-task-descriptors.ts`.
- **El emisor (P2).** `proyeccion.py pasar` lista las raíces, escribe una proyección por raíz con escritura atómica, borra las que ya no aparecen y avisa por `avisar.py`. Manda un consolidado de las raíces con pendientes cada 30 min y avisa una sola vez cada excepción sin respuesta, con reaviso a su `renoticeAfterMs`. El checkpoint (`sistema-agentes.emisor-raices.v1`) avanza solo con un `messageId` positivo, y un candado `flock` deja un solo emisor por máquina. En la Mac, `RaicesPublisher` corre una pasada muda cada 5 min dentro del bucle del host de encargos. En la Mini, el cron de comando `raices-pasada` (`docs/crons/raices-pasada.json`) la corre cada 5 min con `AGENT_WORK_AVISOS=1`. Una raíz rota, una excepción malformada o un gateway colgado quedan en `errores` y no detienen ni el resto de la pasada ni el bucle del host.
- **El ruido de "get no devolvió documento" (P3).** `runbook.progress.get` del plugin `tablero-runbook` contesta `sinRegistro: true` cuando no hay registro administrado ni documento legado. `progress-events.py` archiva esa cola en `archivo-<fecha>`, y el caso del documento legado escribe una línea por cambio de estado, no una por pasada.
- **El panel (P4, decisión A de David).** `/runbook/tablero/raices` y `/runbook/tablero/raices/<rootId>` en el plugin `tablero-runbook`, de solo lectura, con la autenticación del gateway. Hay una segunda pestaña "Raíces" en el Control UI (`operator.read`), por donde entra el celular. Lee solo `<stateDir>/raices/proyecciones`, con `lstat` y `realpath` contenidos, y la CSP usa `script-src` con hash. Las capturas de escritorio y celular de los estados lista, una raíz, vieja, vacía y error se guardaron en `SUA-06-panel-*.png`.

## Estado por invariante

| Invariante | Estado | Evidencia |
|---|---|---|
| I14. Panel y aviso comparten estado y porcentaje; dos tareas, CI en espera y tareas sin PR | **Cumplido, salvo CI en espera.** El panel y el consolidado leen la misma proyección. Dos raíces comparten un consolidado y cerrar una no apaga la otra. Una unidad sin efecto de PR cierra por su evidencia (`raiz-estados`, `unit-c`). Una unidad esperando CI sale como la reporta R (`reported` o `running`), sin un estado propio de "CI en espera" (fila). | `test-agent-work-proyeccion.py` (`test_raiz_estados_porcentajes_y_filas`), `test-agent-work-raices.py` (`DosRaicesUnConsolidado`, `CerrarUnaLaOtraSigue`), `tablero-runbook/raices.test.ts` |
| I15. Móvil y escritorio, teclado, vacío, error, offline y frescura | **Cumplido en el panel elegido (A).** LobsterBoard original no se adoptó (M-26). | `SUA-06-panel-*.png`; `tablero-runbook/index.test.ts` |
| I16. Datos corruptos y métricas ausentes no atribuyen ni matan nada ajeno | **Cumplido.** Un snapshot viejo sale vencido, un JSON roto es un error con nombre y las métricas ausentes son `null`. El PID reutilizado ya lo cubre el host (SUA-03). | `test-agent-work-proyeccion.py`, `test-agent-work-raices.py` |
| I17. Secretos, XSS y rutas maliciosas no se filtran | **Cumplido.** Textos con `<script>`, una llave falsa o una ruta absoluta se recortan o se rechazan, y la vista los escapa. `..%2F` y un `rootId` con `/` contestan 400 sin leer fuera de `raicesDir`. | fixtures `textos-sucios-*`; `tablero-runbook/raices.test.ts` |

## En vivo

Del 2026-10-16 al 2026-10-17 (UTC):

- **R `7615b0a` en la Mini** (reversa a `7b3db54`, foto `pre-7615b0a-20261016-1715`): `managedTasks.root.list` contesta `{"roots": []}`, con el mismo esquema (27) y los mismos 29 crons. La primera vez el instalador se detuvo sin tocar nada: un turno del agente `implementer` sin `session.ended` contaba como vivo. Se instaló por la vía normal cuando ese turno dejó de contar.
- **El plugin `tablero-runbook` en la Mini**, en dos publicaciones. P3 se publicó con `sinRegistro`. P4 se publicó con siete archivos; `index.ts` y `openclaw.plugin.json` llevaron un merge de tres vías para conservar las rutas locales de la Mini. Después de cada reinicio, el plugin quedó `loaded` sin diagnósticos de error y `runbook.progress.get` de una corrida inexistente contestó `sinRegistro: true`. Los respaldos están en `~/.openclaw/backups/tablero-runbook-sua06-*`.
- **El cron `raices-pasada`** (`4a4fb17e`) corre en la Mini cada 5 min desde un checkout fijo de G (`~/.local/share/agent-work/g`, `a7256b59`), con su `failureAlert` a Telegram. Su primera corrida salió `ok` (`{"raices": 0, ...}`): no hay raíces encendidas hasta SUA-09O.
- **En la Mac**, el host de encargos pasó a `a7256b59` y su bucle se reinició sin encargos en curso, así que `RaicesPublisher` escribe en `~/.local/state/agent-work-host/raices`. `~/bin/progress-events.py` quedó en la versión de P3, con respaldo `.antes-sua06-*`. Las colas sin registro (`smoke-*`, `r14`) se archivaron solas en `archivo-2026-10-17` y el ruido "get no devolvió documento" desapareció del log del host. El vigilante `tmux-activity-watch` sigue apagado.

## Los PR

| PR | Merge | Qué trajo |
|---|---|---|
| #332 | `4e188bf2` | Diseño |
| #333 | `8670bba7` | M-26: ensayo de LobsterBoard |
| #334 | `59ba4757` | P1 derivador y P3 `sinRegistro` |
| #335 | `fd906a36` | P2 emisor, `messageId` de `avisar` y el cron de la Mini |
| #336 | `a7256b59` | P4 panel de raíces |

R: P0 en `7afd22d3` y `7615b0ae` sobre `feat/agent-work-integration`, con la compuerta de R en verde.

Implementó GLM 5.3 Flash, relevo de Muse Wonder por cuota (P0 en una segunda ventana). Diseñó y revisó el coordinador (Claude), que hizo M-26, las publicaciones al gateway y la instalación en la Mini, y arregló él mismo los hallazgos de los bots de #334, #335 y #336.

## Lo que queda abierto

Las filas `SUA-06/*` de [followups.md](../agent-work/followups.md). Ninguna es bloqueante.
