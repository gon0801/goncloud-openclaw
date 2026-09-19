# Autopilot de la Fase 12 — tablero de corrida: la pantalla se actualiza sola y sirve a claw y a Hermes

Esto lo ejecutas tú, el **lead**, en autopilot; David no está y no se le pregunta nada. **Hereda `docs/runbooks/base-openclaw.md` v1.0** (roles, lanzamiento, dónde vive cada cosa, precondiciones, reglas de trabajo, compuertas comunes, cola, ventana segura y atores universales): nada de eso se repite aquí. Plan: filas 12.0 a 12.5 de `Plans.md` en `origin/main`; **sus filas mandan en la DoD** y este documento manda en el método. Diseño: `docs/superpowers/specs/2026-09-18-tablero-de-corrida-design.md`. Contrato base: `docs/spec/runbook-progress.v1.md`.

La fase deja el tablero **actualizándose solo y alcanzable por corrida, en cualquier repo**: contrato v2 con clave `corrida` (12.0), el cruce con el plan del repo (12.1), las rutas nuevas y el clic sin configuración (12.2), el render del tablero de referencia (12.3), y el paso de nacimiento en la receta de runbooks (12.4). **No toca el contenido de ninguna corrida ajena, no cambia la configuración del gateway, no reinicia el gateway y no despliega nada fuera del sync normal de `main`.** Versión 1.0, 2026-09-18 UTC.

**Cómo se lanza esta fase (slot 13 de la receta).** El dueño dice una frase —«claw, empieza la Fase 12»— y claw corre **un** comando, con el CLI y el flag sin preguntas del host que elija de su lista:

```
bash scripts/lanzar-fase.sh 12 -- <cli> <flag-sin-preguntas>
```

El script decide solo de qué rama sale el lead (si el runbook ya está en la rama por defecto, de ahí; si no, de la rama que lo trae, y entonces le dice que su Q0 es integrarla), crea `/Users/dn/dev/wt-f12-lead` si falta, arma el mensaje con el sentinel `-saikit:autopilot` y llama a `lanzar-lead.sh`, que marca la sesión y comprueba el cwd del proceso. Termina en `LISTO fase12-lead /Users/dn/dev/wt-f12-lead` o en `ATORADO <razón>`. Con `--dry-run` imprime lo que haría sin tocar nada. **Nadie pega rutas, ramas ni nombres de sesión.**

**La pantalla de esta fase**: `/runbook/tablero/12` desde el primer comando de la corrida, y `/runbook/tablero/c/fase12-tablero` a partir de que Q2 mergee.

## Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| Crear worktrees y ramas `fase12/*` | `/Users/dn/dev/wt-f12-*` | Aprobado |
| Lanzar implementadores en tmux con su flag sin preguntas | los cuatro carriles de esta fase | Aprobado |
| `gh pr create`, `gh pr comment`, `gh pr ready`, `gh api` de lectura | `gon0801/goncloud-openclaw` | Aprobado |
| Revisión cruzada por `cross-review.ps1` | cualquier revisor del conjunto | Aprobado |
| Mergear por la ruta del kit, en ventana segura | los ítems de la cola de abajo | Aprobado |
| `runbook.progress.set` y `runbook.progress.get` | la corrida `fase12-tablero` y lecturas de cualquier otra | Aprobado |
| Editar `~/.claude/skills/autopilot-runbook/SKILL.md` para igualarlo a la copia del repo | solo ese archivo, solo por copia desde `docs/agent-skills/` | Aprobado |
| `config.patch` sobre la configuración del gateway | cualquier clave | **Negado** — 12.2 existe para que deje de hacer falta |
| Reiniciar el gateway | cualquier motivo | **Negado** |
| Escribir en la corrida de otra fase o de otro proyecto | cualquiera | **Negado** — se lee, no se escribe |
| Tocar `scripts/sync-repos.ps1` | cualquier motivo | **Negado** — si se rompe, el gateway no puede bajar su propio arreglo |
| Aflojar la regex de `fase` | cualquier motivo | **Negado** — ahí está cerrado el path traversal |

## Prohibido

Preguntarle algo a David antes del cierre, salvo la única fila que lo permite (base, «la reversa que no entra»). Usar `--no-verify`. Mergear por cualquier ruta que no sea la del kit. Registrar hooks o tools en el plugin: la invariante de blast radius de la Fase 7 es que `tablero-runbook` **no puede alterar, retrasar ni bloquear ningún turno**, y esta fase no la toca. Adivinar la ruta del plan de un repo. Guardar en disco lo que se deriva: el cruce se calcula en la lectura y no se persiste, porque la regla 2 del spec es un solo escritor.

## Carriles

**Antes de nada: Q0.** El lead se lanza con su worktree parado en **la rama de este PR**, no en `main`, porque el documento que ejecuta y las filas cuya DoD obedece viven ahí todavía. Su primer trabajo es mergear Q0 en ventana segura; después, `git fetch origin && git checkout --detach origin/main` y sigue con Q1. Si Q0 ya está mergeado cuando claw lanza, el worktree nace detached en `origin/main` y el lead salta directo a Q1.

**Rama base de los cuatro: `origin/main` fresco**, es decir con Q0 ya dentro. `C` va primero y solo; `A`, `B` y `D` arrancan **después** de que `C` mergee, porque los tres compilan contra los archivos que `C` parte y los tipos que agrega.

| Carril | Rama | Tareas | Quién |
|---|---|---|---|
| **C · Contrato** | `fase12/contrato` | 12.0 | el lead (es spec y un corte mecánico de archivos) — **sin sesión de tmux, sin `BRIEF.md` y sin TIMEBOX**: la regla 15 del base cuenta horas de una sesión de implementador y aquí no hay una. Sí aplica la regla 13: `C` termina con su línea `LISTO <sha>` o `ATORADO <razón>` como cualquier otro carril |
| **A · Núcleo** | `fase12/nucleo` | 12.1, 12.2 | `glm`, si no `cursor-agent`, si no `muse` |
| **B · Pantalla** | `fase12/pantalla` | 12.3 | `cursor-agent`, si no `glm`, si no `muse` |
| **D · Receta** | `fase12/docs` | 12.4 | `muse`, si no `cursor-agent`, si no `glm` |

La DoD de cada tarea es la celda «Criterio de terminado» de su fila en `Plans.md`, verbatim; este documento no la reescribe. La línea «lo que un usuario vería» de cada fila es lo único que recibe el agente `usuario` en 12.5.

## Archivos por carril

| Carril | Puede tocar | No toca |
|---|---|---|
| **C** | `docs/spec/runbook-progress.v2.md`, `tablero-runbook/contrato.ts` y `render.ts` (los dos nuevos, del corte), `tablero-runbook/lib.ts` (queda como reexportador o se borra), `tablero-runbook/index.ts` **solo los `import`** | `plan.ts`, `github.ts`, el cuerpo de `index.ts`, la receta, `base-orbit.md` |
| **A** | `tablero-runbook/plan.ts` y `plan.test.ts` (nuevos), `tablero-runbook/index.ts`, `index.test.ts`, `tablero-runbook/openclaw.plugin.json` | `render.ts`, `contrato.ts`, `github.ts`, los specs, la receta |
| **B** | `tablero-runbook/render.ts` y su prueba | `index.ts`, `plan.ts`, `contrato.ts`, los specs, la receta |
| **D** | `docs/agent-skills/autopilot-runbook/SKILL.md`, `~/.claude/skills/autopilot-runbook/SKILL.md`, `docs/runbooks/base-orbit.md`, `scripts/tests/test-skill-autopilot-runbook.sh` y sus fixtures | todo `tablero-runbook/`, `Plans.md` |
| **cierre** | `Plans.md` (solo celdas de estado), `docs/evidence/usuario-fase12-*.md` | todo lo demás |

`progress.test.ts` y `github.test.ts` los toca **solo** quien rompa su compilación con el corte de `C`, y se declara en el PR.

## Cola de merge

Cada ítem, además de su compuerta propia, pasa la compuerta común del base (CI **de su SHA**, diff de nombres contra la fila de arriba sin salida, PR fuera de borrador) y va en **ventana segura**: mergear a `main` aquí **es** desplegar.

| # | Ítem | Compuerta propia | Fallback |
|---|---|---|---|
| Q0 | El PR de plan y runbook (`a32a1da` y lo que siga) | `git show origin/main:Plans.md \| grep -c '^| 12\.0 '` → `1`, y `bash scripts/arranque-de-fase.sh 12` en VERDE (con el runbook fuera de `main` sale ROJO en las cinco) | Si el PR no mergea, la fase **no arranca**: sin las filas 12.0–12.5 en `main` no hay DoD que obedecer |
| Q1 | C · contrato | `git show origin/main:tablero-runbook/lib.ts \| wc -l` contra el corte: `contrato.ts` + `render.ts` suman lo mismo ±20 líneas, y `bash scripts/run-checks.sh` verde **sin haber editado** `index.test.ts` ni `progress.test.ts` | Si el corte obliga a editar esas pruebas, no es mecánico: vuelve a loop §3 con el diff como encargo |
| Q2 | A · núcleo | `~/.openclaw/bin/openclaw gateway call runbook.progress.get --params '{"fase":"6"}'` sigue devolviendo el documento de la Fase 6 completo (no regresión de la ruta vieja) | Si la ruta vieja se rompe, reversa del ítem por el camino de emergencia del base |
| Q3 | B · pantalla | El HTML del `get` de la Fase 11 trae los cuatro renglones (`A`, `B`, `D`, `R`) y un `%GLOBAL` que **no** es `porcentajeMergeado` | Si el render revienta con un ítem sin carril, vuelve a loop §3 |
| Q4 | D · receta | `bash scripts/tests/test-skill-autopilot-runbook.sh` verde con el candado nuevo, y el fixture malo en rojo cuando se le quita el primer comando | Si la copia de la Mac quedó distinta, se re-copia desde la del repo y se repite |
| Q5 | cierre | La línea `FUNCIONA` del agente `usuario` en `docs/evidence/usuario-fase12-<fecha>.md`, y `bash scripts/cierre-de-fase.sh 12` en `VERDE` con salida 0 | `cierre-de-fase.sh` es un **bucle**: su lista en `ROJO` es la lista de lo que falta |

**12.5 no se cierra leyendo el diff.** El agente `usuario` (fila 9.11) recibe solo la línea «lo que un usuario vería» de cada fila y la URL, abre la pantalla y reporta `FUNCIONA` / `NO FUNCIONA` / `NO PUDE PROBARLO`. Medido 2026-09-17: la Fase 7 pasó sus pruebas, CI en verde y tres PRs integrados, y nadie encendió ni abrió el tablero.

## Progreso de esta fase

**Va después del 0.0 del base y de mergear Q0, y antes de lanzar ningún carril.** El 0.0 comprueba que se puede trabajar; esto abre la pantalla. Primer comando de la fase propiamente dicha — es el paso de nacimiento que 12.4 vuelve obligatorio para todos, y esta fase lo estrena:

```
cat > .saikit/progress/12.json <<'JSON'
{"schema":"runbook-progress.v1","runbook":"docs/runbooks/autopilot-fase12.md","fase":"12",
 "titulo":"Autopilot de la Fase 12 (tablero de corrida)",
 "lead":{"agente":"<host>","inicio":"<ISO>","actualizado":"<ISO>"},
 "atencion_requerida":{"necesaria":false,"motivo":null,"desde":null},
 "siguiente_paso":"Arrancando: el contrato va primero y los otros tres esperan a que mergee.",
 "carriles":[],"cola":[],"eventos":[],"cierre":{"at":null,"telegram_message_id":null,"resumen":null}}
JSON
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/12.json)" --timeout 30000
```

La pantalla queda en `/runbook/tablero/12` desde ese momento. El documento se escribe en v1 **hasta que Q2 mergee** (Q1 es el corte mecánico de archivos: no cambia comportamiento del plugin, así que escribir v2 antes de Q2 solo agrega campos que el plugin todavía ignora); a partir de Q2 se reescribe en v2 con `corrida: "fase12-tablero"`, `proyecto: "openclaw"` y `plan: {"repo":"gon0801/goncloud-openclaw","ruta":"Plans.md","seccion":"Fase 12"}`, y la URL pasa a `/runbook/tablero/c/fase12-tablero`. **La ruta vieja sigue sirviendo**: es la compuerta de Q2.

## Cuando algo se atora (propias de esta fase)

| Situación | Qué hace el lead |
|---|---|
| El corte de `lib.ts` obliga a editar pruebas que no son del carril | No es mecánico: `C` vuelve a loop §3. **No se editan las pruebas para que pase el corte**; eso las volvería incapaces de atrapar una regresión |
| `gh api` de un repo ajeno (Orbit) falla por permisos o cuota al probar 12.1 | Es el caso que la fila exige que degrade: el resultado esperado es «sin verificar», no un error. Si el fixture necesitaba red de verdad, es un fixture mal hecho: se convierte en `execFile` inyectado |
| Un carril propone guardar en disco lo derivado «para no pagar `gh` en cada GET» | Se rechaza y se anota: rompe la regla 2 del spec (un solo escritor, reemplazo completo). Si el costo de `gh` resulta medible, va a una fila del plan, no a este PR |
| La barra de navegación descubierta del disco lista corridas de otros proyectos | Es lo correcto y esperado; el tablero es un servicio del gateway, no de un repo. Si una corrida no debe verse, eso es una fila del plan nueva, no un parche aquí |
| El documento de la Fase 11 de Orbit cambia a media corrida (está vivo) | Se lee, no se escribe. La compuerta de Q3 usa los cuatro renglones que existan en ese momento, no un conteo fijo |

## Inventario

**Cuentas:** 6 tareas, 4 carriles más el cierre, 5 ítems de cola, 1 repo. **Presupuesto:** cuatro sesiones de implementador y las rondas cruzadas; si un proveedor se queda sin cuota, ese carril se detiene y los demás siguen (base). **Fuera de alcance:** el disparador en la Mac que empuja sin esperar al push; mandar avisos desde el tablero (eso es el latido de la Fase 9); un tablero combinado de varios proyectos a la vez; editar el estado desde la pantalla; retrofitear las fases 6 a 11. **Lo que queda listo para David:** un enlace que abre el avance de la corrida que esté pasando en ese momento, en cualquier proyecto, y que se actualiza sin que nadie se acuerde de escribirlo.
