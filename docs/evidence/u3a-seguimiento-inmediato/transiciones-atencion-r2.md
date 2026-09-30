# Atención e inicio en transiciones de base (19.0-r2)

Fecha: 2026-09-29. Resuelve el bloqueante B1 de la revisión de r1: la DoD de
19.0 exige transiciones con detección, envío, atención e inicio, y r1 había
declarado pendientes los dos últimos. Encargo: `encargo-19.0-r2.md`.

## Qué cambió respecto de r1

- **Envío real.** La pasarela (`arnes/openclaw-pasarela`) deja salir por el
  `openclaw` real (CLI 2026.9.6, gateway remoto por SSH) únicamente
  `system event` hacia la sesión propia de la corrida de prueba
  (`agent:main:sim9-arnes19-<id>`); `message send` y `cron list` quedan
  doblados y cualquier otro `system event` queda NEGADO cerrado. El hook Stop
  de claude, que apunta a `agent:main:vigia-mac`, quedó bloqueado por la
  pasarela: a `vigia-mac` no llegó nada. Frontera probada en
  `arnes/test-pasarela.sh`: rojo (sin implementación), verde 6/6, mutación
  que afloja la guarda a `agent:main:*` vuelve el rojo en exactamente los dos
  casos que importan (main:main y vigia-mac), revertida.
- **Atención real.** `arnes/audit-turno.py` consulta `openclaw audit --kind
  agent_run --session <clave> --json` y empareja por `runId` el primer
  `agent.run.started` y su `finished` en la ventana de la corrida.
- **Offset de relojes.** Cinco sondas ssh de solo lectura contra el gateway
  (`powershell [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()`; el remoto
  es Windows) dan la mediana gateway−Mac: entre −471 y −573 ms en las cinco
  corridas. Con ese offset la atención del audit (reloj del gateway) se
  lleva al reloj de la Mac; resolución de las sondas ~1 s.
- **Identidad propia por corrida.** Cada corrida usa
  `arnes19-<token>-<HHMMSS>`: una clave de sesión reutilizada no identifica
  la misma ejecución, y en la primera pasada de zcode el dueño arrastró cola
  de la corrida anterior (un turno arrancó antes del envío). Corregido
  reabriendo con identidad única; zcode y grok se midieron dos veces y la
  tabla usa la corrida limpia.
- **Inicio del siguiente rol.** El sucesor es el siguiente CLI del anillo
  (zcode→codex→kimi→grok→claude→zcode), lanzado sobre el mismo repo de
  ensayo con encargo propio y su entrega verificada por archivo.

## Cadena medida, por CLI

Todo en segundos desde el envío real, salvo la primera columna (fin del
trabajador a envío, con el temporizador de ensayo `QUIET_SECS=10`,
`TICK_SECS=2`; producción usa 900/15).

| CLI (worker) | Fin→envío | Envío→atención | Turno del dueño | Envío→sucesor vivo | Envío→primera actividad | Entrega del sucesor | Veredicto |
|---|---|---|---|---|---|---|---|
| zcode | 8.83 | 8.25 | 34.27 | 53.94 | 54.95 | codex, sí | OK |
| codex | 10.48 | 6.68 | 29.16 | 44.76 | 45.28 | kimi, sí | OK |
| kimi | 10.08 | 7.31 | 63.85 | 81.15 | 81.67 | grok, sí | OK |
| grok | 8.92 | 7.29 | 54.06 | 71.61 | 72.64 | claude, sí | OK |
| claude | −55.97¹ | 67.54¹ | 39.31 | 118.73 | 119.76 | zcode, sí | OK |

¹ El aviso del vigía salió 56 s ANTES del fin y fue el evento de aprobación
`waiting for approval for 0s` (apareció y se contestó en el mismo segundo),
no quietud: a las 18:49:20 el vigía vio ese diálogo en el panel y avisó al
momento (`salidas/claude-r2/doble.*`, primera fila REAL).
El trabajador completó su tarea después: ni un diálogo visto a mitad de turno
ni el silencio acreditan entrega (hallazgo 1 de r1, observado en vivo). La
atención de claude se mide desde ese aviso prematuro; el dueño arrancó 11.5 s
después del fin real del trabajador. Con el envío alineado al fin real, la
atención fue de ~11.5 s.

Corridas descartadas de la tabla, inventario completo (F1/F4, corridas
anteriores al arreglo de identidad única de esta ronda): tres de zcode — el
piloto 18:32 con sesión compartida y cola arrastrada, un relanzamiento fallido
por registro ya existente, y la corrida 18:39 limpia en datos pero con la
atención contaminada por la cola del piloto — y una de grok cuyo sucesor
claude no entregó dentro de la ventana. Conteo completado en C1-r1 (F4): a
esos tres juegos de zcode se suman la corrida de la r1 del arnés
(`salidas/zcode/`, estampa 102610) y un lanzamiento abortado de zcode antes
del registro (sin artefactos), con lo que el total descartado de zcode es
seis; también son anteriores al sello de identidad las corridas de claude,
codex y kimi de esta tabla (F1). Quedan como antecedente en
`arnes/salidas/<token>-r2/` con todas sus estampas. Artefactos crudos:
`doble.*` (envíos REAL y NEGADO), `times-r2.*`, `sondeo*.jsonl`,
`watch.log`, `breve.out`, `registro.*`, `pane-final.log`.

## Qué hizo el dueño al despertar

El aviso del vigía llega con texto fijo ("read the pane before acting"); el
arnés añadió por la misma conexión un breve del lead con el comando exacto
para lanzar al sucesor, por si el dueño tenía brazo ejecutor en la Mac. En
las cinco corridas el dueño despertó (atención de 6.7 a 8.3 s del envío;
67.5 s en claude por el aviso prematuro) y ejecutó acciones `exec` en su
host, pero ninguna alcanzó el sandbox de la Mac: el `audit` es
`metadata_only` y no muestra los comandos, y al terminar sus turnos la
sesión sucesora no existía. El lanzamiento efectivo del sucesor lo hizo el
**lead registrado de la corrida de prueba** (la ruta legacy declara
`sesiones[].dueno="lead"`), declarado aquí como ejecución del arnés y no
como actuación del dueño. Este es el límite real del sistema previo que la
medición deja a la vista: el aviso despierta un dueño que corre en el
gateway (Windows) sin manos sobre el host de las CLI.

## Limitación declarada (lo único que sigue sin observarse)

El efecto de la decisión del dueño sobre el host de las CLI no es ejecutable
en el sistema previo: no hay una ruta del dueño (gateway) al sandbox de la
Mac, y probarla exigiría tocar la configuración del gateway, fuera del
alcance. Por eso "inicio" mide el arranque del siguiente rol ejecutado por
el lead de la corrida de prueba una vez atendido el aviso, no un
lanzamiento ordenado por el dueño. Cerrar ese hueco es justamente el
objetivo de 19.1 (despertar al dueño existente y dejar que compruebe la
entrega), y los números de esta tabla fijan el piso: detección+envío ~9-11 s
con temporizadores de ensayo, atención 6.7-8.3 s, inicio del siguiente rol
45-120 s desde el envío.

Reproducir una transición:

```sh
bash docs/evidence/u3a-seguimiento-inmediato/arnes/medir-r2.sh zcode
```

El arnés se niega a correr sin su pasarela y con estado real; la pasarela
niega cerrado todo `system event` que no vaya a la sesión propia de la
corrida de prueba.
