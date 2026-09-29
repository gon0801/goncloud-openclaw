# Transiciones de base por CLI (19.0)

Fecha: 2026-09-29. Arnés: `arnes/` de este directorio. Una finalización real
de cada CLI habilitada hacia el aviso del seguimiento previo, más un relevo
con cierre provocado. Todo local: servidor tmux propio (`tmux -L`),
`CORRIDA_STATE` de ensayo y `openclaw` doblado (`openclaw-falso`). El gateway
real no participó.

## Método y definiciones

- **Fin del trabajador**: primera observación con el archivo `resultado.txt`
  completo y la cola del panel estable en tres sondeos seguidos (0.5 s cada
  uno). Es un sello conservador: puede llegar hasta ~2 s después del fin
  real del turno.
- **Detección**: primer aviso del vigía o del hook atribuible al trabajador
  medido, contra el sello anterior. Un delta negativo significa que el aviso
  precedió al sello conservador del fin. El resumen automático
  (`calcular-tiempos.py`) descarta avisos anteriores a `fin − 2 s` para no
  contar señales de turnos previos; el análisis definitivo se hizo leyendo
  los `doble.*.jsonl` completos, que es lo que refleja esta tabla.
- **Transporte**: del registro de pared del vigía (`sent:`) a la recepción
  del doble. Los sellos del vigía son de segundo completo: resolución ±1 s.
  Mide el arranque del doble en el mismo host, no el salto real por
  gateway.
- **Relevo**: cierre de sesión provocado por el arnés (ficticio); la
  detección del vigía, el relanzo automático y la primera actividad del
  sucesor son reales.
- Todos los puntos se registran con el reloj monótono del host
  (`time.monotonic_ns`) y su hora de pared; los deltas salen del monótono.
- Configuración del arnés: `QUIET_SECS=10`, `TICK_SECS=2` para que la
  transición sea observable en minutos. Los valores instalados en producción
  siguen siendo `QUIET_SECS=900` y `TICK_SECS=15`; no se midieron aquí.

## Resultados

Encargo: crear `resultado.txt` con `MEDICION-19.0-<token>` usando la
herramienta nativa de archivos, sin terminal.

| CLI | Fin (UTC) | Detección | Transporte | Relevo: cierre→sesión viva | Relevo: cierre→actividad | Veredicto |
|---|---|---|---|---|---|---|
| zcode | 17:25:48.7 | +9.80 s (quietud) | 0.55 s | 0.54 s | 1.57 s | OK |
| codex | 17:28:02.9 | +9.31 s (quietud)¹ | 0.26 s | 2.09 s | 2.61 s | OK |
| kimi | 17:28:56.7 | +8.73 s (quietud) | 0.48 s | 1.56 s | 2.08 s | OK |
| grok | 17:31:11.0 | +9.29 s (quietud)² | n/a³ | 2.07 s | 2.58 s | OK |
| claude | 17:42:16.8 | hook Stop del turno medido a −2.0 s del sello (inmediato dentro de la resolución del sello); quietud +18.19 s como respaldo⁴ | 0.02 s⁵ | 0.54 s | 1.05 s | OK |

¹ Antes del fin, el diálogo de confianza de carpeta disparó un aviso de
 aprobación a las 17:27:51; la carrera del arnés lo respondió en segundos y
 la tarea completó sin más preguntas.
² Además apareció un evento de hook Stop de Claude a −1.86 s con el cwd de
 esta corrida: un proceso claude terminó un turno dentro del árbol de grok
 (lo probable es que grok delegara la creación del archivo). No es una señal
 de fin de grok; la quietud es su señal medida.
³ El aviso llegó antes del primer registro de pared utilizable; el delta no
 es computable. En los demás corrió 0.02-0.55 s.
⁴ Hubo un primer evento de hook a −16.9 s, atribuible al turno de arranque
 de la sesión de precalentamiento (quedó registrada dos veces en el registro
 de la corrida por el relanzo; ver `registro.104239.json`).
⁵ Dentro del ruido de la resolución de ±1 s: para claude el transporte no es
 medible por esta vía.

Artefactos crudos por corrida en `arnes/salidas/<token>/`: `times.*.json`
(resumen), `doble.*.jsonl` (transporte recibido), `sondeo.*.jsonl` (fin y
relevo en monótono), `watch.*.log` (pared del vigía), `registro.*.json`,
`lanzar.*.out` y `pane-final.*.log`.

## Qué no se observó aquí y cómo se cerró en r2

La atención del dueño y el inicio del siguiente rol con transporte real
estaban pendientes en esta medición; la revisión la devolvió por eso
(bloqueante B1) y r2 la completó con el aviso real a la sesión propia de la
corrida de prueba, la atención leída del audit del gateway y el arranque del
sucesor: `transiciones-atencion-r2.md`. Queda allí una limitación declarada:
el lanzamiento del sucesor lo ejecuta el lead registrado de la corrida de
prueba, no el dueño despertado, porque el sistema previo no tiene ruta de
ejecución del gateway al host de las CLI. Todo lo demás de esta sección
está resuelto en el documento r2; los tiempos de detección, transporte y
relevo de esta página siguen siendo la base de comparación.

Reproducir una transición de señal (r1):

```sh
bash docs/evidence/u3a-seguimiento-inmediato/arnes/medir.sh zcode --relanzo
```

Siguen pendientes, ajenos al bloqueante: los recordatorios a 60 min
(`QUIET_REMIND_SECS`, constantes verificadas en código, no esperados en
vivo) y la compactación de main con reinicio diario (configuración del
gateway en Windows, no verificable desde esta Mac).

## Hallazgos de la medición

1. **Los minutos se pierden en la quietud y en la cuadrícula del director.**
   Con los valores instalados, un fin sin hook detectable cuesta hasta
   `QUIET_SECS=900` s más un tick de 15 s, y el dueño solo mira por su cron
   `avance-tareas` cada 15 min (corte consolidado cada 30). La única señal
   inmediata cableada es el hook Stop de claude.
2. **El hook Stop avisa a un canal sin identidad de corrida.** Manda a
   `agent:main:vigia-mac` con texto libre y sin la clave `sim9-<corrida>` que
   sí usa el vigía. El despertar inmediato de claude no llega a la sesión del
   dueño de esa corrida.
3. **La delegación entre CLIs ya ocurre sin identidad.** En la corrida de
   grok, un proceso claude terminó un turno dentro del repo de la corrida y
   su hook disparó el aviso a `vigia-mac` como si fuera el fin del
   trabajador. Un aviso con identidad de encargo distinguiría quién entrega;
   el texto libre no puede.
4. **Un diálogo de permisos sin respuesta genera avisos repetidos.** En la
   primera corrida de claude (encargo con terminal, atascada en un permiso
   de Bash; corrida descartada, artefactos no conservados) el vigía mandó un
   evento de aprobación cada ~5 s durante cinco minutos. El mecanismo es del
   código, no del arnés: la deduplicación de aprobaciones compara la suma de
   las últimas 15 líneas del panel (`tmux-activity-watch.sh:473-481`), y el
   repintado del TUI cambia esa suma en cada tick. En producción equivale a
   un despertar por tick de 15 s mientras el diálogo siga sin atenderse.
5. **`acceptEdits` no cubre terminal.** El mismo encargo que las CLIs en modo
   autónomo completaron sin preguntas dejó a claude esperando aprobación.
   El modo de permisos del registro condiciona qué encargos pueden terminar
   solos.
6. **Desvío de versión en grok.** Host 1.0.44 contra registro 1.0.41. En
   sondas manuales del arnés (sin artefacto conservado) el primer arranque
   mostró un menú inicial y un diálogo de telemetría que retrasaron la barra;
   el segundo arranque la pintó en ~8 s, y la corrida medida pasó sin
   precalentamiento. `pane-final` no se capturaba aún en esa corrida; la
   barra `[stable]` vigente consta en el arranque medido.
7. **El relevo sin modelo recrea la sesión, no el encargo.** `relanzo_
   automatico` llama a `lanzar-sesion` sin `--encargo`: el sucesor arranca
   con la CLI viva pero sin instrucciones; reencargarlo es trabajo del dueño.
   La continuación real con `resume` del carril sí queda medida en la
   práctica 14.13.

## Comandos de validación

Repetir una transición (no toca el servidor tmux real ni el gateway):

```sh
bash docs/evidence/u3a-seguimiento-inmediato/arnes/medir.sh zcode --relanzo
```

El arnés se niega a correr si `TMUX_BIN`, `CORRIDA_STATE` u `OPENCLAW_BIN`
no apuntan a sus dobles. Verificación puntual usada en esta medición:
`<binario> --version` por CLI, `launchctl print-disabled gui/501` para el
latido, `cmp` de las copias `~/bin` contra el repo, y `git rev-parse HEAD`
para el SHA base.
