# Fase 17: centro de tareas para OpenClaw y Hermes

> **NO LANZAR AÚN.** Este runbook es el detalle propuesto para U4/U5 de
> `Plans.md`. Primero se aceptan U1–U3 y se comprueba en 17.0 qué interfaces
> existen en la instalación nueva. El launcher en este documento no es un
> permiso de ejecución ni sustituye la aceptación por host.

Tú eres el lead de ejecución. David no está al teclado: no le haces preguntas durante la corrida. Heredas `docs/runbooks/base-openclaw.md` v1.1 y `docs/runbooks/loop-autopilot.md`. El qué y las DoD están en `Plans.md`, Fase 17; el contrato de producto está en `docs/superpowers/specs/2026-09-22-centro-tareas-design.md`. Si discrepan, manda el spec para producto y `Plans.md` para tareas; detén el carril afectado y corrige el documento inferior en el siguiente PR. Tablero: `/runbook/tablero/c/fase17-centro-tareas`. Localizador: `bash scripts/runbook.sh 17`. Lanzador, **sólo después de autorización para ejecutar y de Q0 integrado**: `bash scripts/lanzar-fase.sh 17 --sesion wt-f17-lead -- <cli-del-lead> <flag-sin-preguntas-verificado>`; nadie adivina el CLI ni su flag. Antes, se permite únicamente `bash scripts/lanzar-fase.sh 17 --sesion wt-f17-lead --dry-run -- <cli> <flag>`.

## Quién y autoridad

El lead es un rol reemplazable: registra progreso, asigna carriles y revisa recibos. Un implementador por carril escribe en su worktree; un revisor distinto juzga el head final. Ingeniería instala en los hosts vivos. David decide una autorización de ejecución y, por separado, cualquier integración o instalación viva. La orden de escribir este runbook sólo autoriza el PR documental.

| Operación | Alcance | Decisión actual |
|---|---|---|
| Redactar, comprobar y publicar este runbook en el PR del Plan 17 | Q0 | Aprobado |
| Arrancar 17.0–17.7, lanzar CLIs, escribir progreso vivo o enviar avisos | Q1–Q4 | Pendiente de pedido de ejecución |
| Integrar Q0 o cualquier PR a `main`; publicar en gateway | Todo merge | Pendiente de autorización explícita |
| Instalar, configurar, emparejar, reiniciar, cambiar crons o hacer tareas reales | 17.8, cada host | Pendiente de autorización por equipo y ventana |
| Leer secretos, copiar credenciales, borrar datos, reescribir historia o saltar hooks | Toda la fase | Negado |

El lead comprueba la autorización aplicable antes de cada ítem. Un CI verde, un recibo o este runbook no amplían su alcance. Mientras falte permiso, registra `ATORADO autorización pendiente` y conserva el PR; no lanza procesos ni solicita una respuesta durante la corrida.

## Arranque y progreso

Q0 es el [PR de planificación](https://github.com/gon0801/goncloud-openclaw/pull/130). Antes de ejecutar, comprueba `git cat-file -e origin/main:docs/runbooks/autopilot-fase17.md` y `git cat-file -e origin/main:docs/superpowers/plans/2026-09-22-centro-tareas.md`. Ambos deben salir 0; si no, Q0 sigue pendiente y se detiene. El launcher puede localizar Q0 en una rama, pero eso **no** autoriza integrarlo. El repositorio es `gon0801/goncloud-openclaw`, default `main`, clon local `/Users/dn/dev/goncloud-openclaw`. Destino OpenClaw Windows: la ruta fuente y la raíz runtime se validan contra los recibos de Fase 16 antes de 17.8. Destino Hermes: `unknown` hasta 17.0; no se inventa ruta ni plataforma.

Tras Q0 integrado y autorización para ejecutar, comprueba sin instalar nada: `test -x /Users/dn/bin/corrida.sh`, `test -r /Users/dn/bin/cli-modos.tsv`, `test -x /Users/dn/bin/tmux-activity-watch.sh` y `test -x /Users/dn/.openclaw/bin/openclaw`. Todos deben salir 0. En la Mac revisada al redactar este documento faltan los dos primeros: es una dependencia de la instalación de Fase 9, no un paso que se improvisa en esta fase. Si falta cualquiera, `ATORADO Fase 9 no instalada` antes de lanzar; 17.0 puede seguir sólo como investigación sin corrida viva. Después de comprobarlos, **el primer bloque de comandos abre la corrida en el tablero** desde el worktree del lead. Reanudar conserva el JSON existente; no vuelve a poner tareas en pendiente. `python3` escribe sólo el estado local inicial, sin secretos:

```bash
python3 - <<'PY'
import datetime, json, pathlib
p = pathlib.Path('.saikit/progress/17.json')
p.parent.mkdir(parents=True, exist_ok=True)
if not p.exists():
    at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    repo = 'gon0801/goncloud-openclaw'
    groups = [('A', 'Contratos', ['17.0', '17.1']), ('B', 'Adaptadores y supervisor', ['17.2', '17.3', '17.4']), ('C', 'Panel e instalador', ['17.5', '17.6']), ('D', 'Revision y aceptacion', ['17.7', '17.8'])]
    lanes = [dict(id=i, nombre=n, repo=repo, rama=None, tareas=t, estado='pendiente', paso_loop=0, pr=None, head=None, approve_lead=None, ci='pendiente', coderabbit='pendiente', residuales=[], detenido_por=None) for i,n,t in groups]
    queue = [dict(id=f'Q{i}', prs=[], estado='verificado' if i == 0 else 'pendiente', ventana=None, merge_commits=[], verificado='ok' if i == 0 else None, detenido_por=None, avance=100 if i == 0 else 0) for i in range(7)]
    doc = dict(schema='runbook-progress.v1', runbook='docs/runbooks/autopilot-fase17.md', fase='17', corrida='fase17-centro-tareas', proyecto='goncloud-openclaw', titulo='Fase 17: centro de tareas', plan=dict(repo=repo, ruta='Plans.md', seccion='Fase 17'), lead=dict(agente='lead', inicio=at, actualizado=at), atencion_requerida=dict(necesaria=False, motivo=None, desde=None), siguiente_paso='Verificar capacidades y dependencias de la fase', carriles=lanes, cola=queue, eventos=[], cierre=dict(at=None, telegram_message_id=None, resumen=None))
    p.write_text(json.dumps(doc, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
PY
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/17.json)" --timeout 30000
```

El RPC sólo publica el tablero OpenClaw. El propio trabajo de 17.3 debe sustituir esa frontera para Hermes; una futura corrida en la otra computadora usa su almacenamiento y transporte local, nunca este gateway. Si falla la publicación inicial, conserva el JSON y detiene el lanzamiento hasta que el tablero responda: esta fase exige seguimiento visible desde el inicio. Una publicación posterior fallida no detiene una corrida ya abierta; se registra y reintenta en el siguiente cambio. Esta es la excepción al reintento no bloqueante del base para el nacimiento de la corrida. El lanzador usa el nombre estable `wt-f17-lead`, que también busca `arranque-de-fase.sh` y reconocerá al reanudar. El lead confirma su marca `OPENCLAW_WATCH=1` y escribe su línea en `.saikit/progress/17-sesiones.txt` antes del chequeo:

```bash
T=/opt/homebrew/bin/tmux
"$T" show-environment -t '=wt-f17-lead' OPENCLAW_WATCH
python3 - <<'PY'
from pathlib import Path
p = Path('.saikit/progress/17-sesiones.txt')
rows = p.read_text().splitlines() if p.exists() else []
p.write_text('lead - wt-f17-lead\n' + ''.join(row + '\n' for row in rows if not row.startswith('lead ')))
PY
```

La marca debe imprimir `OPENCLAW_WATCH=1`; si no, se detiene. Ahora ejecuta `bash scripts/arranque-de-fase.sh 17 --solo-watchdog-global` y exige `VERDE` en las cinco comprobaciones. Abre la corrida una sola vez con `~/bin/corrida.sh abrir fase17-centro-tareas --runbook "$PWD/docs/runbooks/autopilot-fase17.md" --vigia claw`. Si el registro ya existe, lee `~/bin/corrida.sh estado fase17-centro-tareas` y reconcilia antes de reanudar. Ejecuta `~/bin/corrida.sh preflight fase17-centro-tareas` y exige `APTO` antes de cada primer lanzamiento; `NO APTO` detiene el carril hasta corregir su causa. No crea `corrida-vigia-17` ni otro cron. Actualiza JSON y sesiones en cada cambio de carril o cola.

Lanza cada implementador con `corrida.sh lanzar-sesion`:

```bash
~/bin/corrida.sh lanzar-sesion fase17-centro-tareas carril "$TOKEN" "$WT" --nombre "$SESSION" --encargo "$WT/BRIEF.md"
```

`TOKEN` es el ejecutable preflight de 17.0; `WT` es el worktree de la rama del carril y `SESSION` su nombre único `fase17-<carril>-<intento>`. El comando registra la sesión antes de enviar el encargo. Si falla, no se repite sin reconciliar la marca y el intento.

## Carriles y archivos

Cada rama sale de `origin/main` fresco, nunca de la rama de otro carril. La secuencia es A aprobado e integrado antes de B; B aprobado e integrado antes de C; C antes de D. Se comprueba con `git cat-file -e origin/main:docs/spec/centro-tareas.v1.md` para A y con el SHA de merge del PR correspondiente como ancestro de `origin/main` para B/C. Ese contrato es la salida prevista de 17.1; si falta, no se inicia B. No se inicia código que consuma Fase 14 hasta comprobar sus commits mergeados, manifiesto instalado y aceptación; 17.0 y la maqueta de 17.1 pueden avanzar primero. Se comprueban igualmente entrega sin sello A/B/C. Si falta evidencia, queda `unknown` y se detiene sólo el carril dependiente.

| Carril y rama | Filas y DoD de `Plans.md` | Puede tocar | No toca |
|---|---|---|---|
| A `fase17/contratos` | 17.0: Matriz con evidencia por capacidad/host, límites medibles y decisión UI; desconocido no se toma por ausente; gaps requeridos detienen sólo su carril. 17.1: Fixtures legacy/nuevos verdes; identidad y cierre verificable definidos; resumen y reporte coinciden; maqueta cubre estados degradados. | `docs/spec/centro-tareas*`, diseño/fixtures, tests de contrato en `tablero-runbook/` | scripts de instalación, credenciales, hosts vivos |
| B `fase17/seguimiento` | 17.2: Tarea nativa visible con intento y proceso verificables; PID reutilizado y métricas ausentes no se atribuyen mal; guardas existentes pasan. 17.3: Crear, observar, reportar y verificar con OpenClaw ausente; mismo contrato y capacidades requeridas; cobertura parcial explícita. 17.4: Pruebas de crash sin intentos duplicados; efectos inciertos no se repiten; un reloj para dos tareas; recursos/permiso no se amplían al reiniciar. | `scripts/mac/corrida/**`, módulos de progreso y selector de Fase 14, adaptador Hermes y tests focalizados | `tablero-runbook/` UI, estado vivo, secretos |
| C `fase17/panel` | 17.5: Recorridos del diseño verdes en móvil/escritorio; teclado, errores y frescura visibles; API/HTML sin secretos sintéticos ni XSS. 17.6: Instalar dos veces converge; upgrade/reversa conserva tareas; identidades distintas; manifiesto común y credenciales separadas. | `tablero-runbook/**`, instalador/manifiesto de Fase 14 y tests focalizados | código del supervisor B, credenciales o runtime vivo |
| D `fase17/cierre` | 17.7: Hooks y batería completa en CI del head final; reviewer distinto; cero bloqueantes; launcher dry-run y lectura independiente del runbook. 17.8: Mismo sistema probado con el otro runtime inaccesible; recibos por host, checklist y aceptación del usuario; ninguna paridad declarada sin probar ambos. | runbook operativo de despliegue, `docs/evidence/**`, cierre de `Plans.md` tras evidencia | cambios de producto ajenos, secretos, instalación sin permiso |

El lead escribe en cada `BRIEF.md` el resultado visible para David, archivo permitido, DoD literal, test focalizado, límite de recursos, instrucción de no limpiar y línea final `LISTO <sha>` o `ATORADO <razón>` en `.saikit/scratch/<carril>/contrato.txt`. No commitea `BRIEF*.md`. El implementador y el revisor no comparten carril ni sesión. Se aplica `loop-autopilot.md` §§1–5 para encargos, revisión y PR; §§6–10 para integración y cierre **sólo cuando haya permiso**; §§11–13 para atasco y prueba. La primera revisión agrupa hallazgos; otra ronda lee sólo el diff corregido y exige un bloqueante reproducible. No se ejecuta batería completa en la Mac si CI cubre el head final.

## Cola y compuertas

| Ítem | Compuerta observable | Si falla |
|---|---|---|
| Q0 plan/runbook | Ambos archivos figuran en `origin/main`; autorización de integración separada | No iniciar fase |
| Q1 A | 17.0 documenta versión/plataforma/API, licencia de LobsterBoard, formatter y dependencias; 17.1 tiene tests de contratos y maqueta | `ATORADO` en capacidad faltante; seguir sólo diseño independiente |
| Q2 B | Q1 A aprobado e integrado en `origin/main`; Fase 14 y entrega sin sello con recibos; tests OpenClaw y Hermes con el otro ausente; crash y reloj único | No iniciar B sin Q1; no declarar paridad; corregir en B |
| Q3 C | Q2 B aprobado e integrado en `origin/main`; UI y paquete pasan tests móvil/escritorio, XSS, instalación doble y reversa en entornos temporales | No iniciar C sin Q2; corregir C sin instalación viva |
| Q4 revisión | PR por bloque con commits propios, hooks y CI del SHA final; cero bloqueantes; lectura externa del runbook | Mantener PR abierto y corregir sólo bloqueantes reproducibles |
| Q5 aceptación | Autorización por equipo/ventana; Fase 16 aceptada donde aplique; tarea real de bajo riesgo en cada host con otro inaccesible | Conservar 17.8 `cc:TODO`; no llamar completa a la fase |
| Q6 cierre | Recibos de ambos hosts, checklist una vez por SHA, `bash scripts/cierre-de-fase.sh 17` VERDE y PR único de ledger | Declarar pendiente la fila sin evidencia |

Cada PR documenta implementador, pruebas focalizadas, residuales y head. CI corre batería completa una vez por bloque en los shards del PR; lectura de docs/ledger va en el job corto. Si CI no cubre la batería completa, ejecutar sólo lo faltante. `git log origin/main..HEAD` debe listar sólo commits del carril. Un follow-up no bloqueante se registra en una fila nueva del plan y en el PR; no entra a la cola de integración de otro bloque. El lead no mergea por cuenta propia: espera autorización explícita y usa la ruta del kit definida en el base, en ventana segura. Un head nuevo invalida el CI y recibo previos. El PR de cierre `fase17/cierre-ledger` nace de `origin/main` después de los bloques y actualiza sólo estados con evidencia.

## Cuando algo se atora

| Situación | Acción cerrada |
|---|---|
| Q0 no integrado o falta permiso | Conservar PR y estado, imprimir `ATORADO autorización pendiente`; no lanzar |
| Fase 14, entrega sin sello o Fase 16 sin recibo aplicable | Registrar evidencia faltante; seguir sólo tareas independientes; no inferir cerrado del chat |
| Hermes carece de API pública de continuación | Marcar capacidad `unknown` o ausente con prueba; no usar RPC privadas ni prometer paridad; detener 17.3/17.4 |
| Licencia de LobsterBoard no apta o no verificable | Usar `tablero-runbook/` con diseño propio; no copiar código del candidato |
| CI o revisor no disponibles | Conservar PR/head y registrar `unknown`; consultar cuando haya evento, sin polling continuo ni segunda batería |
| Estado corrupto o envío fallido | Mostrar `desconocido`, conservar último dato válido y evidencia; nunca reiniciar corte ni repetir efecto externo incierto |
| Presupuesto, cuota o recursos agotados | Detener nuevos lanzamientos y mantener el registro; reanudar sólo con presupuesto existente y capacidad medida |
| Instalación o reversa falla | Conservar recibos, parar sólo ese host; no afectar el otro ni borrar datos |

## Inventario, seguimiento y cierre

Un repo y un PR por bloque más el PR de cierre; cuatro carriles, un implementador escritor por carril, reviewer distinto y una instalación por equipo. Presupuesto de compras: cero. El límite inicial de ejecución es un worker local; 17.0 fija cifras medibles de muestreo, retención y presupuesto. OpenClaw Windows y Hermes se aceptan por separado; plataforma/ruta Hermes siguen `unknown` hasta 17.0. No hay transferencia de tareas entre equipos, visor agregado, botones de ejecución, acceso remoto ni segundo reloj.

La condición terminal de implementación es 17.0–17.7 con revisión y CI del head final. El cierre operativo exige también 17.8. Si falta autorización viva, conservar el estado y reportar `ATORADO aceptación por host pendiente`; no imprimir `LISTO` de fase. Tras Q0 y autorización de ejecución, David sólo necesita decir: «empieza la Fase 17».

## Seguimiento

El lead informa a David en cada cambio de estado mediante `corrida.sh` y `seguimiento.v2`. El canal es Telegram, con el destino leído del cron que ya entrega; no se escribe aquí. El vigía corre cada 15 minutos y el consolidado sale al menos cada 30 minutos mientras haya trabajo activo. Los avisos excepcionales usan `seguimiento.v1` de inmediato. El lead actualiza `.saikit/progress/17.json` y su copia del gateway en cada cambio y cierre. Durante 17.3, la instalación Hermes debe demostrar su propio transporte y reloj con la misma cadencia; hasta entonces no se afirma que esté cubierta. No manda un aviso por CLI ni por carril.

## Clases de comando

| Clase | Uso |
|---|---|
| gh | PRs, checks y recibos de los bloques |
| red externa | Documentación oficial, licencia y GitHub, sin secretos |
