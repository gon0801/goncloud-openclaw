# Fase 9: cierre de corridas autónomas

> **Revalidar antes de lanzar.** La ruta activa es U2 de `Plans.md`. El sync
> Windows y el watchdog se deshabilitaron durante la reinstalación; este
> runbook no puede asumir que mergear despliega ni crear un segundo reloj.
> Conservar PR #100 y ejecutar sólo las filas faltantes tras U1.

Para el lead que Claw asigne. Hereda `docs/runbooks/base-openclaw.md` v1.1 y `docs/runbooks/loop-autopilot.md`. Plan: `docs/superpowers/plans/2026-09-21-fase9-cierre.md`; diseño: `docs/superpowers/specs/2026-09-21-fase9-cierre-design.md`. Pantalla: `/runbook/tablero/9` desde el primer comando.

## Arranque

Primer comando: crea `.saikit/progress/9.json` conforme a `runbook-progress.v1` con carriles D, I, U y S en `pendiente`, cola Q0–Q5, `siguiente_paso: "Integrar Q0 y recuperar PR 100"`, lo envía y abre la pantalla:

```bash
mkdir -p .saikit/progress
python3 - <<'PY'
import datetime, json, pathlib
now=datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
lane=lambda i,n,r,t:{"id":i,"nombre":n,"repo":"gon0801/goncloud-openclaw","rama":r,"tareas":t,"estado":"pendiente","paso_loop":0,"pr":None,"head":None,"approve_lead":None,"ci":"pendiente","coderabbit":"pendiente","residuales":[],"detenido_por":None}
queue=lambda i:{"id":i,"prs":[],"estado":"pendiente","ventana":None,"merge_commits":[],"verificado":None,"detenido_por":None}
doc={"schema":"runbook-progress.v1","runbook":"docs/runbooks/autopilot-fase9.md","fase":"9","corrida":"fase9-cierre","proyecto":"openclaw","titulo":"Cierre de Fase 9","plan":{"repo":"gon0801/goncloud-openclaw","ruta":"Plans.md","seccion":"Fase 9"},"lead":{"agente":"unknown","inicio":now,"actualizado":now},"atencion_requerida":{"necesaria":False,"motivo":None,"desde":None},"siguiente_paso":"Integrar Q0 y recuperar PR 100","carriles":[lane("D","Docs","fase9/docs",["9.7","9.13"]),lane("I","Instalacion","fase9/instalacion-cierre",["9.10","9.16"]),lane("U","Usuario","fase9/usuario",["9.11","9.12"]),lane("S","Simulacro","sin-rama",["9.0","9.9"])],"cola":[queue(f"Q{i}") for i in range(6)],"eventos":[],"cierre":{"at":None,"telegram_message_id":None,"resumen":None}}
pathlib.Path('.saikit/progress/9.json').write_text(json.dumps(doc,ensure_ascii=False)+"\n")
PY
~/.openclaw/bin/openclaw gateway call runbook.progress.set --params "$(cat .saikit/progress/9.json)" --timeout 30000
open 'http://127.0.0.1:18789/runbook/tablero/9'
```

Después corre el 0.0 del base, sustituyendo su línea de arranque por `bash scripts/arranque-de-fase.sh 9 --solo-watchdog-global`, y verifica: `origin/main` contiene PRs #81, #97, #98, #104 y #110; PR #100 sigue abierto sobre `fase9/docs`; `ai.goncloud.corrida-latido` no está cargado; el vigilante global vive. Una celda vieja de `Plans.md` no invalida un merge comprobado. Q0 es este plan/runbook si aún no está integrado.

Claw lanza con `bash scripts/lanzar-fase.sh 9 -- <cli> <flag-verificado>`. El sentinel solo arma las instrucciones del turno; el merge usa un recibo persistente del PR y no depende de sello, sesión, host ni cwd.

## Roles y preaprobaciones

Claw elige al lead por disponibilidad. El lead dirige, registra y hace la auditoría final; no implementa código. D, I y U tienen implementador propio; reviewer/verifier no son autores. `usuario` prueba solo la promesa y la ruta humana.

| Operación | Alcance | Decisión |
|---|---|---|
| worktrees, tmux, push, PR, recibo y merge por kit | ramas D/I/U y cierre, en el orden de la cola | Aprobado |
| instalación con respaldo `.anterior` | solo desde el SHA integrado de `origin/main` | Aprobado |
| Telegram real | solo mensajes `[SIMULACRO]` de S y progreso global ya instalado | Aprobado |
| CLI real barato, reloj inyectado y sesiones `sim9-*` | simulacro 7/7, máximo 10 min de pared | Aprobado |
| gateway config, secretos, otro cron, `ai.goncloud.corrida-latido`, borrado recursivo | toda la fase | Negado |

Prohibido: reimplementar filas ya integradas; abrir reemplazo de PR #100; rebase, amend, force-push o `--no-verify`; cambiar de trabajador para escapar de una prueba/revisión; repetir batería completa para el mismo SHA; activar un segundo reloj; implementar Fases 14, 15, 23, 9.17 o 9.18.

## Carriles y archivos

Cada carril sigue los Tasks homónimos del plan, incluida su DoD y sus comandos focalizados.

| Carril / rama | Filas | Propiedad |
|---|---|---|
| D `fase9/docs`, PR #100 | 9.7, 9.13 | alcance existente del PR; watcher/runner, loop, skill y guía |
| I `fase9/instalacion-cierre` | 9.10, 9.16 | `scripts/mac/instalar-mac.sh`, corrida cerrar/lib y pruebas focalizadas |
| U `fase9/usuario` | 9.11, 9.12 | `agents/usuario/`, cierre de fase, skill y pruebas focalizadas |
| S sin rama de código | 9.0, 9.9 | instalación integrada, simulacro y evidencia |
| C `docs/fase9-cierre` | ledger | `Plans.md`, `.saikit/progress/9*`, evidencia final |

D primero: `git fetch origin && git merge origin/main` en su worktree; nunca se duplica. I puede prepararse desde `origin/main`, pero U nace después de integrar D. I/U comparten PR solo si `git diff --name-only` demuestra propiedad disjunta y cada fila conserva commit/prueba propia; si no, se serializan. Todo worker recibe un `BRIEF.md`, escribe contrato y no hace push/PR.

Preferencia de trabajador, saltando binarios/proveedores sin cuota, auth o arranque: D `muse → cursor-agent → glm`; I `glm → cursor-agent → muse`; U `cursor-agent → glm → muse`. El relevo conserva worktree, rama, brief y commits. Reviewer/verifier siempre independientes.

## Entrega y cola

Pruebas focalizadas al editar. Una batería completa por PR, en CI sobre el SHA final; si ese CI no cubre la batería, se completa una vez donde sí. Hooks obligatorios. Primera cross-review del carril completo; CodeRabbit una vez al promover. Solo un bloqueante reproducible abre corrección y cross-review del delta con otro revisor; mismo bloqueante dos rondas seguidas ⇒ `ATORADO`. No bloqueantes de I/U van al Bloque D de entrega-sin-sello.

| Cola | Compuerta |
|---|---|
| Q0 plan/runbook | pruebas focalizadas de docs, CI final, recibo persistente; integrar antes de código |
| Q1 PR #100 | 9.7 preservada; reproducción y arreglo de 9.13; cross-review, CodeRabbit, CI |
| Q2 I | 9.10 y 9.16 verdes, ningún old heartbeat, revisión/CI |
| Q3 U | 9.11 y 9.12 verdes, `usuario` no leyó código, revisión/CI |
| Q4 S | instalado desde `origin/main`; 7/7 `FUNCIONA`; `[SIMULACRO]`; ≤10 min pared |
| Q5 cierre | evidencia, estados honestos, `bash scripts/cierre-de-fase.sh 9` en VERDE |

Antes de iniciar Q4, instala con `bash scripts/mac/instalar-mac.sh` desde el
`origin/main` integrado y comprueba que no quedó una copia parcial de
`corrida.sh`:

```bash
bash scripts/mac/instalar-mac.sh &&
for f in lib abrir lanzar-sesion terminar-sesion reconciliar-marcas cerrar preflight estado latido responder seguimiento migrar-seguimiento; do test -x "$HOME/bin/corrida/$f.sh" || { echo "FALTA $f" >&2; exit 1; }; done
```

El recibo `saikit-entrega.v1` del PR nombra head, roles y workflow de CI. Reiniciar o cambiar el lead no exige repetir revisión. El merge usa el kit con head esperado; ninguna sesión produce un sello. El PR de cierre reúne todas las celdas/evidencias de la fase y no vuelve a revisar el código ya aprobado.

## Seguimiento

El lead escribe progreso en cada cambio de estado. El watchdog global manda cada 30 minutos, mientras haya trabajo activo, un solo mensaje con: `% fase`, `% por carril`, terminado, en curso, atorado y siguiente paso. No crear cron por fase. Al terminar un carril, quitar solo su marca; al cerrar, quitar marcas de Fase 9 y conservar el vigilante global si hay otro trabajo.

## Cuando algo se atora

| Situación | Acción |
|---|---|
| PR #100 trae conflicto | resolver solo sus archivos declarados; prueba focalizada; push normal al mismo PR |
| cuota/auth/binario/arranque falla | detener candidato anterior y relevar al siguiente; registrar causa; no duplicar proceso vivo |
| prueba o CI rojo | mismo carril corrige el fallo reproducido; no cambiar de modelo ni reiniciar CI sin SHA nuevo |
| CodeRabbit sin cuota/20 min | declarar indisponible y continuar; no fingir aprobación |
| recibo ausente/inválido | corregir el comentario persistente del PR; no buscar sello ni sesión antigua |
| latido viejo cargado | descargarlo y comprobar que el watchdog global sigue vivo antes de S |
| simulacro no logra 7/7 | dejar 9.9 abierta con evidencia; no cerrar por tiempo ni convertir requerido en `unknown` |
| cierre rojo | cada línea es trabajo pendiente; corregir evidencia/estado, no aflojar el script |

## Inventario y cierre

Inventario esperado: 3 carriles de código/documentación, 1 simulacro, 1 PR de cierre; 9.17–9.18 quedan en Block D; Fase 14 espera 9+15 y Fase 23 no espera esta fase. Respaldos instalados y temporales se enumeran en evidencia; no se borran durante la corrida.

El cierre reconcilia 9.0–9.16 con PR/SHA/evidencia reales, deja 9.17–9.18 pendientes con su destino y termina solo cuando `bash scripts/cierre-de-fase.sh 9` imprime `VERDE: la fase 9 puede declararse cerrada`. Última línea del lead: `LISTO <sha-del-cierre>`.

## Clases de comando

| Clase | Uso |
|---|---|
| `gh` / red GitHub | PR, comentarios, recibo, CI y merge autorizado |
| OpenClaw RPC/Telegram | progreso y mensajes `[SIMULACRO]`, sin leer secretos |
| tmux/launchd | sesiones marcadas, instalación y verificación autorizadas |
