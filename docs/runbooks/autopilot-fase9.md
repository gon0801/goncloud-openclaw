# Autopilot de la Fase 9 — corridas autónomas con seguimiento

Esta página es para ti, **el lead** que corre la Fase 9 en autopilot. David no está al teclado y **no se le pregunta nada para decidir**: lo que necesitas decidir ya está decidido aquí o en el loop. Lo que sí cambia en esta fase, por pedido suyo: **David recibe mensajes de seguimiento durante toda la corrida, escritos para él y no para un ingeniero**, y si algo de verdad necesita su respuesta se le manda el mensaje y **se sigue con todo lo demás**; nunca se espera parado.

Cuatro carriles en un solo repo, un spike tuyo, una instalación en la Mac y un simulacro vivo al final.

**Lo que no está escrito aquí está en `docs/runbooks/loop-autopilot.md`**: el loop por tarea (§3), las rondas de revisión con su comando literal (§4), PRs y CodeRabbit (§5), la ruta del kit con su sello (§6), ventana segura (§7), progreso (§8), reanudación (§9), revisión de cierre (§10) y los atores universales (§12). Este runbook **no los repite**; solo nombra sus desviaciones. **Manda el loop que esté en `origin/main` en el momento en que lo consultas**: el carril D lo edita a media fase, y lo que cambie vale desde su merge.

**Tres convenciones para todo el documento.** Primera: todo `openclaw` que corras es `~/.openclaw/bin/openclaw`; pelado da "command not found". Segunda: todo comando se corre desde `/Users/dn/dev/wt-f9-lead` salvo donde diga otra ruta. Tercera: tmux siempre es `/opt/homebrew/bin/tmux`.

---

## Qué runbook manda

Manda **este archivo tal como está en `origin/main`**. Llegó ahí junto con el plan, en el PR #61; 0.0 comprueba que ese PR ya se mergeó. No hay otra versión.

Fuente del plan: `Plans.md`, Fase 9, tareas 9.0 a 9.9. Si el plan y este runbook difieren en el **método**, manda este runbook. Si difieren en la **DoD de una tarea**, manda `Plans.md`: la revisión de cierre (loop §10) se hace contra la DoD literal del plan. No se conoce ninguna diferencia al escribir esto; la que aparezca se **declara** en el PR de cierre, no se edita.

---

## Quién

| Rol | Quién | Qué hace en esta fase |
|---|---|---|
| **lead** | tú: un CLI en tmux, de cualquier host del kit, elegido y lanzado por claw | Spike 9.0, encargos, lanzar implementadores, auditoría, revisión, APPROVE, merges, instalación en la Mac, simulacro 9.9, cierre, **y los mensajes de seguimiento**. No escribes código de producto. |
| **implementador N** | el que lances; preferencia: `glm`, `cursor-agent`, `muse` | Núcleo: 9.1, 9.2, 9.3 |
| **implementador M** | preferencia: `cursor-agent`, `glm`, `muse` | Mensajes: 9.4, 9.5, 9.8 |
| **implementador P** | preferencia: `glm`, `cursor-agent`, `muse` | Política de diálogos: 9.6 |
| **implementador D** | preferencia: `muse`, `cursor-agent`, `glm` | Docs: 9.7 |
| **claw** | el agente `main` del gateway | Te lanzó. Manda el parte de cada hora a David, te empuja si te quedas ocioso con trabajo pendiente (sección siguiente), te relanza si mueres (loop §9), y en el simulacro es el vigía real. No mergea. |
| **David** | el dueño | Lee los mensajes. Su única acción posible: contestar un `NECESITO TU RESPUESTA`, si llega uno. |

Solo se usan esos tres tokens de implementador porque son los que tienen su modo sin preguntas **medido** (tabla de "Cómo se lanza"). `muse` va al final salvo en docs: con esfuerzo máximo murió dos veces la noche del 2026-09-16 por `model stream idle timeout after 180000ms`, causa `unknown` hasta 9.0. Dos carriles pueden usar el mismo token a la vez: son sesiones y worktrees distintos.

**Escribe quién implementó cada carril** en el cuerpo de su PR, con esa palabra exacta: de ahí sale el `-Excluir` de la revisión cruzada (loop §4). `muse` y `cursor-agent` no son candidatos a revisor: con ellos se pasa `-Excluir ''`.

---

## Quién te despierta

Tu turno termina en cuanto dejas de tener algo que hacer, y un carril tarda horas. La noche del 2026-09-16 el lead de la Fase 7 lanzó sus carriles, su turno terminó a los cuatro minutos y nadie lo volvió a despertar. El vigilante de tmux le avisa a **claw**, no a ti. Por eso hay dos mecanismos, y los dos se arman:

**1. Tú esperas de forma activa.** Antes de cerrar un turno en el que queda algo pendiente, dejas una espera **acotada** corriendo en segundo plano con la ejecución en segundo plano de tu host (la que te vuelve a invocar cuando el comando termina). Para un carril:

```
S=<sesión>; n=0
until /opt/homebrew/bin/tmux capture-pane -p -t "$S" -S -40 2>/dev/null | grep -q -E '^ *(LISTO [0-9a-f]{7,}|ATORADO )' \
   || ! /opt/homebrew/bin/tmux has-session -t "$S" 2>/dev/null || [ $n -ge 120 ]; do n=$((n+1)); sleep 30; done
echo "fin de espera: $S"
```

Sale cuando el carril imprime su línea de contrato, cuando su sesión muere, o a los 60 minutos; al volver miras la pantalla y, si sigue trabajando, la vuelves a armar. Para CI: `gh pr checks <n> --watch --interval 30`, también en segundo plano. Para un tope de reloj (los del simulacro, la ventana segura, los 20 minutos de CodeRabbit de loop §12): `n=0; until [ $n -ge <minutos> ]; do n=$((n+1)); sleep 60; done`. **Regla: nunca cierras un turno sin una espera armada, salvo que tu última línea sea `LISTO <sha>` o `ATORADO <razón>`, o que tu host no tenga ejecución en segundo plano.** En ese último caso lo anotas una vez en el progreso (`sin espera propia: dependo del empuje`) y tu única red es el mecanismo 2.

**2. claw te empuja.** Si tu host no tiene ejecución en segundo plano, o la espera se perdió, el cron `corrida-empuje-9` (0.4) hace que claw mire cada 15 minutos: si tu sesión está ociosa y algún carril terminó, se atoró, murió, espera a una persona **o lleva un tick entero con la pantalla congelada**, y eso no te lo empujó ya, escribe **una línea** en tu sesión que empieza con `[vigia]`. Usa dos archivos suyos, los dos bajo `~/.local/state/corrida-fase9/`: `pantallas.txt`, donde anota en cada vuelta lo que vio en cada pantalla (así sabe cuál lleva un tick entero congelada), y `empujado.txt`, donde guarda lo último que te avisó (así un carril que dice `LISTO` y se queda ahí no te despierta cada quince minutos el resto de la fase). Esa línea solo puede traer una de seis palabras (`TERMINO`, `ATORADO`, `PERMISO`, `MUERTA`, `CALLADO`, `TRABAJA`), nunca texto copiado de una pantalla; una que traiga otra cosa se ignora y se anota en el progreso. Es un aviso, no una orden: al recibirla, miras tus carriles con `capture-pane` y sigues el runbook donde ibas. Es el único que escribe en tu sesión, y no escribe en ninguna otra.

Un implementador que pide permiso le llega a claw por el vigilante; **claw no lo contesta**: te lo pasa con su línea `[vigia]`, y quien contesta eres tú (fila de atores). Esto se aparta de loop §1 ("claw contesta lo mecánico") y de su skill viva `mac-tmux-control`, que le dice que conteste con la tabla de preaprobaciones: aquí la tabla la tienes tú y dos actores tecleando en la misma sesión se pisan. Lo que las distingue es **el nombre**: toda sesión que esta fase lanza lo lleva `wt-f9-` adentro, la tuya incluida, desde el primer minuto y sin depender de nada que esta fase construya. La tuya la nombra claw al lanzarte (`<token>-wt-f9-lead`), y es la **única** en la que puede escribir, solo con la línea `[vigia]` del cron de empuje. La frase que se lo ordena a claw va en la instrucción con la que te lanza (última sección), y es la misma que tú le repites si te empuja mal.

---

## Arranque

Repo único: `/Users/dn/dev/goncloud-openclaw`, default `main`, copia desplegada en el gateway `C:\Users\ehven\.openclaw`, que el sync actualiza cada 2 h a los :10 de las horas impares en `America/New_York`. El código de esta fase corre en la Mac, pero **dos cosas sí llegan al gateway**: todo merge a `main` baja en el siguiente sync (por eso la ventana segura de loop §7 aplica a cada merge), y el carril D edita dos skills de claw, que son sus instrucciones vivas.

**Dónde te paras.** El clon principal puede estar en otra rama y con cambios de otra sesión: no trabajas ahí.

```
cd /Users/dn/dev/goncloud-openclaw && git fetch origin
git worktree list                      # mira qué hay ANTES de crear nada
git worktree add /Users/dn/dev/wt-f9-lead --detach origin/main
cd /Users/dn/dev/wt-f9-lead
```

Después de **cada** merge de la cola, pones tu worktree al día: `git fetch origin && git checkout --detach origin/main`. Tus archivos sin trackear (progreso, evidencia) sobreviven.

| Worktree | Ruta | Rama |
|---|---|---|
| lead | `/Users/dn/dev/wt-f9-lead` | detached en `origin/main` |
| N | `/Users/dn/dev/wt-f9-N` | `fase9/nucleo` |
| M | `/Users/dn/dev/wt-f9-M` | `fase9/mensajes` |
| P | `/Users/dn/dev/wt-f9-P` | `fase9/politica` |
| D | `/Users/dn/dev/wt-f9-D` | `fase9/docs` |
| revisión por commit | `/Users/dn/dev/wt-f9-rev` | detached en el SHA que se revisa; se crea y se borra dentro de la misma revisión, así que **si ya existe cuando vas a crearlo, no es tuyo**: usa `wt-f9-rev-b` y anótalo |
| corrección tras un merge | `/Users/dn/dev/wt-f9-fix` | `fase9/fix-<carril>` |
| reversa | `/Users/dn/dev/wt-f9-revert` | `fase9/revert-<carril>` |
| cierre | `/Users/dn/dev/wt-f9-cierre` | `fase9/cierre` |

`git worktree add` falla si la ruta existe. **Nunca `--force`.** Una ruta que ya existe **es tuya** si está en la tabla de arriba y `git -C <ruta> rev-parse --abbrev-ref HEAD` imprime la rama que le toca (`fase9/…`, o `HEAD` en las detached): se reúsa tal cual, con lo que tenga adentro (un carril a medio trabajo está sucio por definición, y eso es lo esperado). Si imprime **otra** rama, es trabajo ajeno en una ruta que se llama igual: fila de atores. Para `wt-f9-lead`, que nace detached y sin carril, la comprobación es esta, y tiene que salir vacía:

```
git -C /Users/dn/dev/wt-f9-lead status --porcelain | grep -v -E '^\?\? (\.saikit/|docs/evidence/fase9-|BRIEF)'
```

- [ ] **0.0 Precondiciones.** Una comprobación por línea, para saber cuál falla:

```
G=~/.openclaw/bin/openclaw
git cat-file -e origin/main:docs/runbooks/autopilot-fase9.md 2>/dev/null; echo runbook=$?
git show origin/main:Plans.md | grep -c -E '^\| 9\.[0-9] '                                # plan: debe imprimir 10
git show origin/main:Plans.md | grep -E '^\| 7\.[0-9] ' | grep -c -E 'cc:(TODO|WIP)'      # fase7: debe imprimir 0
git cat-file -e origin/main:.saikit/autopilot.json 2>/dev/null; echo autopilot=$?
test -r /Users/dn/dev/summonaikit-claude/tools/saikit-merge.sh; echo kit=$?
bash scripts/tests/test-runbooks-no-contradicen-entorno.sh >/dev/null 2>&1; echo candado=$?
bash scripts/tests/test-loop-autopilot.sh >/dev/null 2>&1; echo loop=$?
$G gateway call status --timeout 30000 >/dev/null 2>&1; echo gateway=$?
pgrep -f 'bin/tmux-activity-watch.sh' >/dev/null; echo vigilante_vivo=$?
```

Lectura: en las líneas `nombre=$?`, cero es presente y cualquier otro valor es ausente. `plan` distinto de `10`: el PR #61 no está mergeado. `fase7` distinto de `0`: **la Fase 7 no ha cerrado y esta fase no arranca**. No es burocracia: las dos fases editan `docs/runbooks/loop-autopilot.md`, `docs/agent-skills/autopilot-runbook/SKILL.md` y `Plans.md`, y corriendo a la vez chocan. Medido al escribir esto (2026-09-17): `fase7` imprime `8` y `plan` imprime `0`, así que las dos sí pueden salir por el otro lado.

**Si es un arranque nuevo, cualquier precondición que falle detiene la fase**, salvo `gateway`: sin gateway se puede construir y probar (todo es de la Mac), así que la fase arranca, el seguimiento se reintenta en cada cambio de estado, y Q4 espera al gateway **dos horas como máximo** antes de cerrarse como "sin simulacro". **Si te relanzaron**, 0.0 es informativo: `fase7`, `plan` y `runbook` ya se cumplieron al arrancar y no se vuelven a exigir. La señal de que te relanzaron es que `.saikit/progress/9-sesiones.txt` traiga **al menos una línea de carril** (una línea que no empiece con `lead` ni con `cron`): eso solo existe si la fase llegó a lanzar a alguien. Un arranque detenido en 0.0 deja `9.json` pero ninguna línea de carril, así que el siguiente lanzamiento vuelve a exigir las precondiciones.

**Toda detención de la fase** hace tres cosas, en este orden: se declara con la salida verbatim en el progreso (si el archivo todavía no existe, se crea ahí mismo con ese único evento); se manda el mensaje `DETENIDA` (regla 1; si `CHAT` todavía no está leído, primero se corre el bloque de 0.4 que lo lee, sin crear crons); y se imprime `ATORADO <razón>` como último acto del turno. Sin esa línea, claw lee el silencio como un lead muerto y te relanza sobre el mismo problema (loop §2 y §12).

Lo que 0.0 no puede comprobar: que el hook del kit selle en tu host (loop §6). Se descubre en el `--dry-run` de Q1; si ahí sale "sin estado del hook", la fase se detiene con un solo carril trabajado.

- [ ] **0.1 Lee** la Fase 9 de `Plans.md` y el loop entero.

- [ ] **0.2 Márcate.** Tu propia sesión también se vigila (loop §12, "la del lead incluida"):

```
[ -n "${TMUX_PANE:-}" ]; echo en_tmux=$?
YO=$(/opt/homebrew/bin/tmux display-message -p -t "$TMUX_PANE" '#S'); echo "$YO"
case "$YO" in *wt-f9-*) echo nombre=0;; *) echo nombre=1;; esac
/opt/homebrew/bin/tmux set-environment -t "$YO" OPENCLAW_WATCH 1
/opt/homebrew/bin/tmux show-environment -t "$YO" OPENCLAW_WATCH      # debe imprimir OPENCLAW_WATCH=1
```

`nombre` distinto de cero: claw no te nombró como dice la última sección. No es una detención: te renombras con `/opt/homebrew/bin/tmux rename-session -t "$YO" '<token>-wt-f9-lead'`, vuelves a leer `$YO` y lo anotas; sin ese nombre en la sesión, claw contestaría tus diálogos. `en_tmux` distinto de cero: no estás dentro de tmux y nadie podría verte ni relanzarte; es una detención de la fase (`ATORADO lead fuera de tmux`). La comprobación va contra `TMUX_PANE` y no contra lo que imprima `display-message`: sin `-t`, tmux contesta con la sesión más reciente **aunque no estés dentro de ninguna**, y marcarías la sesión de otra persona (medido 2026-09-17).

- [ ] **0.3 Primer progreso y su espejo.** Escribe `.saikit/progress/9.json` (loop §8) con los cuatro carriles en `pendiente`, y `.saikit/progress/9-sesiones.txt` con una sola línea: `lead - <tu sesión>`. Al relanzar, esa línea se **reemplaza**, no se agrega. Luego corre el espejo de la regla 4. Si `runbook.progress.set` responde "método desconocido", el tablero de la Fase 7 quedó apagado: se anota una vez en `eventos` y el intento se repite en cada cambio, como manda loop §8.

- [ ] **0.4 Abre el seguimiento.** El destino de Telegram no se escribe en ningún archivo: se lee del cron que ya entrega ahí.

```
G=~/.openclaw/bin/openclaw
CHAT=$($G cron list --json 2>/dev/null | python3 -c "
import sys,json
t=sys.stdin.read(); d=json.loads(t[t.index('{'):])
print(next(((j.get('delivery') or {}).get('to') or '' for j in d.get('jobs',[]) if j.get('name')=='verif-sync-repos'),''))")
test -n "$CHAT"; echo chat=$?
```

`chat` distinto de cero con `gateway=0`: el cron `verif-sync-repos` ya no existe o cambió de forma; fila "sin destino". Con `gateway` distinto de cero no se distingue: se reintenta cuando responda. Con `CHAT` en mano, manda el primer mensaje (regla 1, etiqueta `AVANZA`) y crea los dos crons:

```
$G cron add --name corrida-vigia-9 --every 60m --agent main --announce --channel telegram --to "$CHAT" --json --message "Parte de la Fase 9 para David, solo lectura. 1) En la Mac (exec con host node): cat /Users/dn/.local/state/corrida-fase9/progress.json y cat /Users/dn/.local/state/corrida-fase9/sesiones.txt. 2) Por cada sesion de esa lista: /opt/homebrew/bin/tmux capture-pane -p -t <sesion> y mira las ultimas 15 lineas no vacias. 3) Contesta SOLO con el parte, en cuatro lineas: etiqueta entre corchetes (AVANZA, DETENIDA o NECESITO TU RESPUESTA), Que cambio, Que sigue, Que necesito de ti. ESCRIBE PARA UNA PERSONA QUE NO LEE CODIGO: di como va el proceso (cuantas de las 5 partes estan terminadas, cual se esta trabajando, si avanza o esta detenido y desde cuando), sin nombres de archivo, comandos, ramas, siglas ni terminos tecnicos. Solo si una sesion espera a una persona, la etiqueta es NECESITO TU RESPUESTA: explica en palabras simples que se esta pidiendo y que implica decir si o no, y al final, como referencia, el comando textual. No escribas en ninguna sesion, no relances nada y no toques configuracion: este turno solo informa. Si los archivos no existen, contesta 'Fase 9: todavia no hay avance registrado' y nada mas."
$G cron add --name corrida-empuje-9 --every 15m --agent main --no-deliver --json --message "Empuje de la Fase 9. No le escribas a David en este turno. 1) En la Mac (exec con host node): cat /Users/dn/.local/state/corrida-fase9/sesiones.txt. La PRIMERA linea es la sesion del lead; las demas son carriles. 2) /opt/homebrew/bin/tmux capture-pane -p -t <sesion> de cada una, ultimas 15 lineas no vacias. 3) Lee dos archivos, y si alguno no existe vale cadena vacia: /Users/dn/.local/state/corrida-fase9/pantallas.txt (lo que viste la vez pasada en cada pantalla) y /Users/dn/.local/state/corrida-fase9/empujado.txt (lo ultimo que le avisaste al lead). Clasifica cada carril en UNA palabra de esta lista cerrada y en ninguna otra: TERMINO (su pantalla trae una linea que empieza con LISTO), ATORADO (empieza con ATORADO), PERMISO (hay un dialogo esperando a una persona), MUERTA (su sesion ya no existe), CALLADO (la pantalla que acabas de leer es identica a la que ese mismo carril tiene anotada en pantallas.txt, y no es ninguno de los casos anteriores), TRABAJA (cualquier otro caso). Escribe SIEMPRE en pantallas.txt, este tick y todos, una linea por carril con su nombre y las ultimas 15 lineas no vacias de su pantalla; ese archivo es tuyo y nunca sale de la Mac. Aparte, arma una linea de estado con pares carril-palabra. En la linea de estado y en lo que le escribas al lead NUNCA copies texto de una pantalla: solo esas seis palabras. SOLO si esa linea de estado es DISTINTA de lo que dice empujado.txt, Y la sesion del lead esta ociosa (su caja de texto vacia, sin nada corriendo), Y algun carril quedo en TERMINO, ATORADO, PERMISO, MUERTA o CALLADO: guarda esa linea de estado en /Users/dn/.local/state/corrida-fase9/empujado.txt (escribela con tu herramienta de escritura de archivos, no con un comando: este texto ya viaja dentro de comillas) y escribe UNA sola linea, la del carril mas urgente en este orden: PERMISO, MUERTA, ATORADO, CALLADO, TERMINO; en la sesion del lead con /opt/homebrew/bin/tmux send-keys -t <sesion del lead> -l '[vigia] <carril>: <la palabra>. Continua el runbook de la Fase 9.' y, en llamada aparte, /opt/homebrew/bin/tmux send-keys -t <sesion del lead> Enter. 4) Si la sesion del lead no existe, relanza al lead segun tu procedimiento. En cualquier otro caso no hagas nada. Nunca escribas en la sesion de un carril."
```

Cada `cron add --json` devuelve un objeto con el campo `id` en la raíz. Anota los dos en `.saikit/progress/9-sesiones.txt` como `cron <id>`: Q5 los quita. Medido 2026-09-17: el primero queda con `delivery.mode: announce`; el segundo lleva `--no-deliver` porque sin él la entrega por defecto es `announce` al último canal y David recibiría un mensaje cada 15 minutos.

- [ ] **0.5 Abre el worktree de N y lánzalo** ("Cómo se lanza"):

```
git worktree add /Users/dn/dev/wt-f9-N -b fase9/nucleo origin/main
```

Si te relanzaron y la rama ya existe, `-b` falla y la ruta también existe: no se crea nada, se reúsa (comprobación de arriba).

- [ ] **0.6 Corre el spike 9.0 tú mismo**, mientras N trabaja. Su sección está abajo.

---

## Preaprobaciones del dueño

| Operación | Alcance | Decisión |
|---|---|---|
| `git push` + `gh pr create` | Todo PR de esta fase: N, M, P, D, corrección, reversa y cierre | Aprobado |
| Merge por la ruta del kit (loop §6) | Todo PR de esta fase, en el orden de la cola; `--confirmado` con este runbook como el sí escrito | Aprobado |
| Lanzar implementadores en tmux sobre worktrees desechables, en su modo sin preguntas | Carriles N, M, P, D | Aprobado |
| Mensajes de Telegram a David por `openclaw message send` | Todo el seguimiento de la regla 1, y los del simulacro con el prefijo `[SIMULACRO]`. Rutina con `--silent`; `NECESITO TU RESPUESTA` con notificación | Aprobado |
| Crons en el gateway | **Solo estos tres**: `corrida-vigia-9` y `corrida-empuje-9` (0.4 a Q5), y `corrida-vigia-simulacro-9`, que crea y quita `corrida.sh` durante Q4 | Aprobado |
| Que claw escriba una línea `[vigia]` en **tu** sesión | El cron `corrida-empuje-9` | Aprobado |
| Cualquier otro cron, `openclaw.json`, modelos, auth, permisos o configuración del gateway | Toda la corrida | **Negado** |
| Tocar `scripts/sync-repos.ps1` | Toda la corrida. Si se rompe, el gateway no puede bajar ni su propio arreglo (plan, 9.8) | **Negado** |
| Instalar en la Mac: `corrida.sh`, `corrida/`, `cli-modos.tsv` a `~/bin/`; el LaunchAgent `ai.goncloud.corrida-latido`; reinstalar el vigilante desde `origin/main` con su reinicio | Solo en Q4, con el código ya mergeado, y con respaldo `.anterior` de lo que se pisa | Aprobado |
| Escribir `~/.claude/skills/autopilot-runbook/SKILL.md` | El carril D, como copia exacta de la del repo, antes de commitear; y tú en Q3 si quedó distinta | Aprobado |
| `corrida.sh responder` mandando teclas a una sesión | **Solo** sesiones de la corrida `simulacro-9` | Aprobado |
| `corrida.sh responder` activo en cualquier otra corrida | 9.6 nace apagada (regla 5). Encenderla para corridas reales es decisión de David después de leer el simulacro | **Negado** |
| Matar sesiones de tmux | **Solo** cuatro clases: una que tú acabas de crear y **todavía no empezó a trabajar** (su pantalla nunca mostró que leyera el encargo), que cubre la fila "a los 60 s la caja sigue vacía"; las del spike, de nombre `spike9-…`; las del simulacro, de nombre `sim9-…`; y una sesión de carril **comprobada parada** con las dos capturas de la fila de relanzamiento | Aprobado |
| Un CLI real barato (`glm`) en el simulacro | 9.9; cuota mínima | Aprobado |
| Leer el historial de claw por RPC (`chat.history` de `agent:main:main`) | 9.0 (e) y evidencia del simulacro. **Solo se cita lo que claw hizo y a qué hora; jamás texto escrito por David** (lo vigila `scripts/tests/test-evidencia-sin-texto-de-usuario.sh`) | Aprobado |
| `ssh`, o cualquier salida de red que no sea GitHub, el gateway o el proveedor del modelo | Los candados de la sesión lo niegan y no se rodean. Lo que dependa de eso queda `unknown` | **Negado** |
| Borrado destructivo (`rm -rf`, `DROP`) | Toda la corrida, también bajo `/tmp`: el hook lo vuelve pregunta (loop §12) | **Negado** |

---

> **Prohibido toda la corrida:** esperar parado una respuesta de David; cerrar un turno sin una espera armada (salvo `LISTO`, `ATORADO`, o un host sin ejecución en segundo plano, que lo anota una vez); tocar el gateway fuera de los tres crons de la tabla; tocar `scripts/sync-repos.ps1`; leer o imprimir cualquier secreto (el lanzador `~/bin/glm` contiene un token: se ejecuta, jamás se lee ni se pega; `~/.ssh` no se abre); escribir el destino de Telegram en un archivo del repo; que una **prueba automática** mande un Telegram real o despierte a un agente vivo (el simulacro sí lo hace, marcado `[SIMULACRO]`); pegar texto de una pantalla dentro de comillas dobles de un comando; mandar teclas a una sesión que no sea de esta corrida; limpiar con borrados destructivos; `git worktree remove --force`; rebase, amend o force-push; `--no-verify`; mergear por fuera del kit.

---

## Cómo se lanza un implementador

Medido el 2026-09-17, después de que los dos carriles de la Fase 7 arrancaran mal con un comando escrito a medias. **El PATH y el flag van dentro del comando**, y la sesión se marca **antes** de mandarle nada.

| Token | Flag sin preguntas (`<flag>`) | Cómo se comprueba que entró, 10 s después de crearla |
|---|---|---|
| `glm` (zcode) | `--mode yolo` | la barra de abajo dice `yolo`; sin flag dice `build` |
| `cursor-agent` | `-f --trust` | la pantalla **no** contiene `Do you trust the contents of this directory?` y sí muestra su caja de texto |
| `muse` | `--yolo` | la barra termina en `YOLO` |

```
T=/opt/homebrew/bin/tmux
BIN=$(bash -c 'PATH=$HOME/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH; command -v <token>')
S=<token>-wt-f9-<carril>
$T has-session -t "$S" 2>/dev/null && echo YA-EXISTE || \
  $T new-session -d -s "$S" -x 200 -y 50 -c /Users/dn/dev/wt-f9-<carril> "PATH=/opt/homebrew/bin:/Users/dn/.local/bin:/Users/dn/bin:\$PATH $BIN <flag>"
$T has-session -t "$S"; echo viva=$?
$T set-environment -t "$S" OPENCLAW_WATCH 1
n=0; until [ $n -ge 5 ]; do n=$((n+1)); sleep 2; done
$T capture-pane -p -t "$S" | grep -v '^[[:space:]]*$' | tail -4
```

`<token>` es el primero de la lista de preferencia del carril cuyo `command -v` imprime una ruta; `<carril>` es `N`, `M`, `P` o `D`; `<flag>` es el texto literal de la tabla. La captura va sin líneas en blanco porque tmux devuelve la pantalla entera y la barra no está en las últimas filas si debajo hay vacío (medido: con `tail -4` a secas sale en blanco). `YA-EXISTE`: si la sesión está en `9-sesiones.txt` es tuya de antes y la reúsas; si no está, es de otra persona y usas el nombre con sufijo `-b`. `viva` distinto de cero: el binario murió al arrancar; se corre directo (`"$BIN" --help`) para leer el error, no se reintenta a ciegas. Si la captura no muestra la comprobación de la tabla, matas **esa** sesión recién creada (`$T kill-session -t "$S"`; todavía no tiene contexto) y la vuelves a crear; a la segunda, siguiente token de la lista.

Anota `<carril> <token> <sesión>` en `.saikit/progress/9-sesiones.txt`, corre el espejo (regla 4) y entrega el encargo, **como archivo**:

```
$T send-keys -t "$S" -l 'Lee /Users/dn/dev/wt-f9-<carril>/BRIEF.md y haz lo que pide'
$T send-keys -t "$S" Enter
n=0; until [ $n -ge 5 ]; do n=$((n+1)); sleep 2; done
$T capture-pane -p -t "$S" | grep -v '^[[:space:]]*$' | tail -6
```

El `Enter` va en llamada aparte. Si la captura todavía muestra la frase en la caja de texto, manda **un** `Enter` más y vuelve a capturar. **Arrancó** cuando la captura muestra que leyó el archivo. Después armas tu espera ("Quién te despierta").

**Todo `BRIEF.md` de esta fase lleva, además de lo de loop §3:** (a) "no limpies: nada de `rm -rf` ni borrados recursivos, ni bajo `/tmp`; usa `mktemp -d` y deja lo que crees"; (b) "ninguna prueba manda un Telegram real ni un evento real: `OPENCLAW_BIN` apunta a un stub que solo anota sus argumentos, y tmux corre con servidor propio (`-L`)"; (c) "compatible con `/bin/bash` 3.2 de macOS"; (d) "cada prueba imprime `TODO VERDE: <nombre>` como última línea cuando pasa"; (e) "todo script encuentra a sus hermanos relativo a sí mismo (`$(dirname "$0")`): instalado vive en `~/bin/corrida.sh` y `~/bin/corrida/`, no en el repo"; (f) "el rojo de cada tarea va pegado en `.saikit/scratch/<carril>/tdd.md`"; (g) "las correcciones van como commits nuevos `fix(9.x): …`, nunca amend"; (h) "no instales nada ni toques `~/bin`, `~/Library/LaunchAgents` ni `launchctl`: la instalación es del lead en Q4"; (i) "los lanzadores de `~/bin` con permisos 700 (`glm`, `glm-claude`, `deepseek`, `kimi-claude`) contienen tokens: se ejecutan, jamás se leen ni se pegan"; (j) "no hagas push ni abras PR"; (k) la fila de su carril de la tabla de archivos, copiada de aquí. `BRIEF*.md` no se commitea.

---

## El spike 9.0

Lo corres tú, solo lectura, mientras N trabaja. **No bloquea a ningún carril.** Salida: `docs/evidence/fase9-spike.md` en `wt-f9-lead`, una línea `veredicto <tema>: <valor>` por tema, con el comando y su salida pegados debajo. Entra al repo en el PR de cierre. Las sesiones de prueba se llaman `spike9-muse` y `spike9-dsh`, **no se marcan ni se anotan** en `9-sesiones.txt`, y se matan al terminar el tema.

| Tema | Qué corres | Si no se puede |
|---|---|---|
| (a) Hermes | Nada: Hermes entra a la Mac por SSH desde otra máquina y aquí no deja rastro. | `veredicto hermes: unknown`, con las tres preguntas del plan escritas para que David se las pase. Nada depende de la respuesta: Hermes lee `eventos.jsonl` por SSH. |
| (b) muse y el timeout | `bash -c '/Users/dn/.local/bin/muse --help'`: buscar `reasoning-effort`. Un encargo de razonamiento largo a `spike9-muse` en un `mktemp -d`, con tope de 10 min. | `unknown` con lo que sí se vio. Un solo intento. |
| (c) `muse --yolo` y la red | No se prueba: tus candados niegan la salida de red. | `unknown`; lo medirá el primer carril de muse que corra un `pre-commit`. |
| (d) `dsh` | `bash -c '/opt/homebrew/bin/dsh --help'`, y lanzarlo en `spike9-dsh` para capturar el error. | `unknown` con el error textual. |
| (e) claw ante un aviso | `~/.openclaw/bin/openclaw gateway call chat.history --params '{"sessionKey":"agent:main:main","limit":40}' --json`: qué herramienta usó claw, y a qué hora, en el turno que siguió a un aviso `waiting for approval`. | `unknown` si ese turno ya no está. |
| (f) SSH PC→Mac | `/usr/local/bin/tailscale status`: si el par de la PC va `direct` o por `relay`. | Las 50 conexiones cronometradas se corren desde la PC: `unknown` con el comando escrito. |

---

## Carriles

**Rama base de todos: `origin/main` en el momento de abrir el worktree**, después de `git fetch origin`. Ningún carril nace de otro carril.

**Orden.** N va solo y primero: trae los contratos, la biblioteca y el envío de mensajes que usan los demás. **M y P se abren cuando N ya está mergeado**, en paralelo, con archivos disjuntos. **D se abre cuando M y P ya cerraron**, mergeados o `atorado`. Así nunca hay más de tres PRs propios abiertos (loop §5). Los comandos, cuando toca:

```
git fetch origin
git worktree add /Users/dn/dev/wt-f9-M -b fase9/mensajes origin/main
git worktree add /Users/dn/dev/wt-f9-P -b fase9/politica origin/main
git worktree add /Users/dn/dev/wt-f9-D -b fase9/docs     origin/main
```

**Cuando un carril queda mergeado o `atorado`, desmarcas su sesión** (`/opt/homebrew/bin/tmux set-environment -t <sesión> -u OPENCLAW_WATCH`) y la dejas abierta: marcada seguiría mandándole a claw un recordatorio de silencio cada 30 minutos hasta Q5.

**Si un carril termina `atorado`** (TIMEBOX, segundo relanzamiento o cuota): **N** atorado es una detención de la fase, porque todo depende de él. **M** atorado: P sigue; D se abre con lo que haya; Q4 instala lo que exista y el simulacro corre solo los escenarios que no dependen del latido (1, 2, 3, 5 y 6); 9.4, 9.5 y 9.8 quedan declaradas. **P** atorado: M sigue; D se abre; Q4 instala sin `responder` y los escenarios 2 y 3 quedan "no observado"; 9.6 es Recommended y la fase cierra sin ella. **D** atorado: Q4 corre igual; 9.7 queda declarada.

### N · Núcleo — rama `fase9/nucleo`

Tareas 9.1, 9.2 y 9.3, un commit por tarea, en ese orden. **DoD: la de cada fila del plan, entera.** Además, cuatro cosas de forma que fija este runbook: (1) `scripts/mac/corrida.sh` es solo un despachador que carga `corrida/<subcomando>.sh` **relativo a sí mismo**, para que M y P agreguen subcomandos sin tocar archivos de N; la biblioteca es `corrida/lib.sh` y ahí vive `corrida_mensaje`; (2) `scripts/tests/fixtures/tui-falso.sh` es el TUI de mentira: repinta cada 0.2 s el archivo `pantalla.txt` del directorio donde arranca y termina la pantalla con la línea `TUI-FALSO`; (3) `scripts/tests/fixtures/corrida/cli-modos-simulacro.tsv` trae la fila `tui-falso` (binario: la ruta absoluta de ese script en `wt-f9-lead`; comprobación de barra: `TUI-FALSO`) además de la de `glm`; (4) `scripts/tests/fixtures/corrida/runbook-simulacro.md` es un runbook mínimo con su tabla de clases de comando, para que el preflight tenga qué leer.

### M · Mensajes — rama `fase9/mensajes`

Tareas 9.4, 9.5 y 9.8, un commit por tarea. **DoD: la de cada fila.** Además: el latido escribe cada evento que produce en `~/.local/state/corridas/<id>/eventos.jsonl` (lo que lee un vigía que no está en el gateway); el reloj y el binario de `openclaw` son inyectables por variable de entorno; y **el latido ignora todo directorio de `~/.local/state/corridas/` que no tenga registro `corrida.v1` válido**.

### P · Política — rama `fase9/politica`

Tarea 9.6. **DoD: la de la fila.** Además: (1) `responder` **nace apagado**: solo actúa si existe `~/.local/state/corridas/<id>/responder.on`; sin ese archivo registra en `decisiones.jsonl` qué **habría** hecho y no manda ninguna tecla; (2) el enganche en `scripts/mac/tmux-activity-watch.sh` que lo invoca es de este carril, y con `responder` apagado o ausente el vigilante se comporta como hoy (prueba: la batería actual del vigilante sigue verde sin tocar sus casos); (3) el vigilante anexa cada evento que manda a `~/.local/state/tmux-activity-watch/eventos.jsonl`; (4) los fixtures de pantalla se llaman `scripts/tests/fixtures/dialogos/confianza.txt` y `scripts/tests/fixtures/dialogos/permiso-push.txt` (un permiso para `git push origin main`): el simulacro los usa por ese nombre.

### D · Docs — rama `fase9/docs`

Tarea 9.7. **DoD: la de la fila.** El candado de paridad (`scripts/tests/test-skill-autopilot-runbook.sh`) compara la skill del repo con `~/.claude/skills/autopilot-runbook/SKILL.md` y corre en el pre-commit: **cada vez que D edite la del repo, copia el archivo entero a esa ruta antes de commitear**, o su commit sale rojo. Los candados nuevos de 9.7 exentan por nombre a los runbooks de las fases 6, 7, 8 y 9 (lo dice la fila del plan): D no toca ningún runbook de fase.

### Archivos por carril

Todos los carriles pueden escribir además `.saikit/scratch/<su carril>/`, que **sí** se commitea (loop §3 paso 2).

| Carril | Puede tocar | No toca |
|---|---|---|
| N | `scripts/mac/corrida.sh`, `scripts/mac/corrida/{lib,abrir,lanzar-sesion,cerrar,preflight}.sh`, `scripts/mac/cli-modos.tsv`, `docs/spec/corrida.v1.md`, `docs/spec/seguimiento.v1.md`, la sección "Corridas autónomas" de `docs/spec/00-project-spec.md`, `scripts/tests/test-corrida-nucleo.sh`, `scripts/tests/test-corrida-preflight.sh`, `scripts/tests/test-cli-modos.sh`, `scripts/tests/fixtures/corrida/`, `scripts/tests/fixtures/tui-falso.sh` | El vigilante, el loop, las skills, `Plans.md` |
| M | `scripts/mac/corrida/{estado,latido}.sh`, `scripts/mac/ai.goncloud.corrida-latido.plist`, `scripts/tests/test-corrida-estado.sh`, `scripts/tests/test-corrida-latido.sh`, `scripts/tests/fixtures/estado/` | Lo de N y de P (solo **usa** `lib.sh` y `cli-modos.tsv`); el vigilante; `scripts/sync-repos.ps1` |
| P | `scripts/mac/corrida/responder.sh`, `scripts/mac/tmux-activity-watch.sh`, `scripts/tests/test-corrida-responder.sh`, `scripts/tests/test-tmux-activity-watch.sh` (solo **agregar** casos), `scripts/tests/fixtures/dialogos/` | Lo de N y de M (solo usa `lib.sh` y `cli-modos.tsv`) |
| D | `docs/runbooks/loop-autopilot.md`, `docs/runbooks/guia-del-vigia.md`, `docs/agent-skills/autopilot-runbook/SKILL.md` y su copia en `~/.claude/skills/autopilot-runbook/SKILL.md`, `agents/main/agent/workshop-skills/{agent-dispatch,mac-tmux-control}/SKILL.md`, `scripts/tests/test-loop-autopilot.sh`, `scripts/tests/test-runbooks-no-contradicen-entorno.sh`, `scripts/tests/test-skill-autopilot-runbook.sh`, `scripts/tests/test-guia-del-vigia.sh`, la parte (4) de anclas de `scripts/tests/test-tmux-activity-watch.sh`, y **solo si un ancla suya cambió** por editar esas dos skills: `scripts/tests/test-{mac-tmux-control,agent-dispatch-no-merge,agent-dispatch-spawn,mac-path-regla,camino-feliz,saikit-cierre-pr-merge-owner}.sh` | Código bajo `scripts/mac/`; cualquier `docs/runbooks/autopilot-*.md` |
| cierre | `Plans.md` (celdas `Status` de 9.0 a 9.9 y nada más), `docs/evidence/fase9-spike.md`, `docs/evidence/fase9-simulacro-<AAAA-MM-DD>.md`, `.saikit/progress/9.json`, `.saikit/progress/9-sesiones.txt` | Todo lo demás |

Si un carril necesita un archivo que no está en su fila, no lo toca: lo dice en su reporte y tú mandas un encargo `BRIEF-r<N>.md` al carril dueño; si el dueño ya está mergeado, es una corrección tras un merge (fila de atores).

---

## Reglas propias de esta fase

1. **Seguimiento: un mensaje en cada cambio de estado, escrito para David.** Él quiere saber **cómo va el proceso**, no cómo está hecho. Se escribe a un archivo con un heredoc entre comillas simples, que no expande nada, y de ahí se manda:

   ```
   M=$(mktemp); cat > "$M" <<'MSG'
   [<ETIQUETA>] Fase 9 · <n> de 5 partes terminadas
   Qué cambió: <una frase>
   Qué sigue: <una frase>
   Qué necesito de ti: nada
   MSG
   ~/.openclaw/bin/openclaw message send --channel telegram -t "$CHAT" --silent --json -m "$(cat "$M")"
   ```

   `<ETIQUETA>` es una de cuatro: `AVANZA`, `DETENIDA`, `NECESITO TU RESPUESTA`, `CERRADA`. Las **5 partes** son: núcleo, mensajes, política de diálogos, documentación, y simulacro con cierre. **Lenguaje de usuario, sin excepciones:** sin nombres de archivo, comandos, ramas, SHAs, números de PR, siglas ni las palabras commit, merge, worktree, CI o hook. Se dice "la parte de mensajes quedó integrada y probada", no "mergeé el PR de M con CI verde"; "la IA que construye la primera parte lleva dos horas trabajando", no "glm en wt-f9-N". El detalle técnico va en el PR. En `NECESITO TU RESPUESTA` se quita `--silent`, y la última línea explica en palabras simples **qué se está pidiendo y qué implica cada opción**; el comando textual va al final, solo como referencia. Texto que venga de una pantalla entra **solo** por el heredoc, nunca dentro de comillas dobles: un `$( )` copiado de un diálogo lo ejecutaría tu shell. Un carril que lleva 30 minutos con la pantalla quieta sin haber terminado **es** un cambio de estado y su mensaje sale por esta regla: así ninguna espera pasa de 30 minutos sin que David sepa. **Tope:** un `AVANZA` a menos de 15 minutos del mensaje anterior se junta con el siguiente cambio (y si no hay siguiente, lo cubre el parte de la hora); las otras tres etiquetas salen siempre de inmediato. La hora del último envío se guarda en `.saikit/progress/9-ultimo-mensaje.txt` (`date +%s`). `CHAT` se vuelve a leer con el bloque de 0.4 si tu shell lo perdió. Un envío que falla no bloquea: se anota en `eventos` y se reintenta en el siguiente cambio. De cada envío se guarda en `eventos` **solo** el `messageId` y si salió bien: la respuesta trae el destino de Telegram, y `9.json` entra al repo en el PR de cierre. El parte de cada hora **no es tuyo**: lo manda claw, y es el que sigue hablando si tú mueres.
2. **No se limpia durante la corrida** (loop §12). Ni tú ni tus subagentes. Directorios con `mktemp -d`; lo que quede se declara en el cierre.
3. **Un commit por tarea dentro del carril, y las correcciones como commits nuevos** `fix(9.x): …`; nunca amend. La revisión cruzada sabe revisar un commit (loop §4, `-Alcance last-commit`): cada commit del carril se revisa parado en él, con `git worktree add --detach /Users/dn/dev/wt-f9-rev <sha>`, el comando de loop §4 corrido desde ahí, y al terminar `git worktree remove /Users/dn/dev/wt-f9-rev` (sin `--force`: está limpio). Una **ronda** es revisar todos los commits nuevos desde la ronda anterior; el tope de tres rondas de loop §4 cuenta por PR.
4. **Progreso y su espejo.** El progreso es `.saikit/progress/9.json` (la fase es `9`) y las sesiones van en `.saikit/progress/9-sesiones.txt`: primera línea `lead - <sesión>`, después una por carril (`<carril> <token> <sesión>`), y los crons como `cron <id>`. `paso_loop` se satura en 8, como en la Fase 7. Después de **cada** escritura de cualquiera de los dos:

   ```
   mkdir -p ~/.local/state/corrida-fase9 && cp .saikit/progress/9.json ~/.local/state/corrida-fase9/progress.json && awk '$1!="cron"{print $3}' .saikit/progress/9-sesiones.txt > ~/.local/state/corrida-fase9/sesiones.txt
   ```

   Esa copia es lo que leen los dos crons de claw. Vive **fuera** de `~/.local/state/corridas/`, que es la raíz donde `corrida.sh` guardará sus registros.
5. **9.6 nace apagada.** Se construye, se prueba y se ejercita **solo** dentro del simulacro. Al terminar Q4: `find ~/.local/state/corridas -name responder.on | wc -l` debe imprimir `0`; si queda uno, se renombra a `responder.off` con `mv`, no se borra.
6. **TIMEBOX: 6 horas de reloj por carril**, desde su lanzamiento hasta su `LISTO`. Si pasó tiempo detenido en un diálogo, al quedar otra vez trabajando su TIMEBOX **vuelve a 6 horas completas**. Un encargo de corrección `BRIEF-r<N>.md` no abre otro TIMEBOX: tiene 2 horas. A su tope, el carril pasa a `atorado` con lo que tenga.
7. **Base al día con merge, nunca con rebase** (loop §3 paso 9). `main` avanza sola cada dos horas con los snapshots del gateway, así que el kit va a contestar "base avanzada" en casi todo merge: en el worktree del carril, `git fetch origin && git merge origin/main`, push normal, CI de nuevo, y re-APPROVE si `git diff <sha aprobado> HEAD -- <archivos de la fila del carril>` sale vacío. El commit de merge no cuenta como commit ajeno en la compuerta común.
8. **Sello y merge en el mismo turno** (loop §6), **y el `cd` lo sostienes tú**: el hook sella con la huella del directorio de proyecto de la sesión, y en algunos hosts un subagente pierde el `cd` entre llamadas. Así que el `cd /Users/dn/dev/wt-f9-<carril>` lo haces en tu hilo principal antes de despachar al revisor, el veredicto lo escribe tu subagente desde ahí, y el merge se corre desde ahí antes de cerrar ese turno, ya dentro de la ventana segura. Un turno que cierra limpio borra el sello.

### Desviaciones, nombradas

**Del loop:** §1 dice que David "solo lee el Telegram de cierre"; en esta fase recibe seguimiento continuo, por pedido suyo del 2026-09-17. §3 paso 5 y §4 no aplican al PR de cierre ni a uno de reversa: son celdas de estado y evidencia ya producida, o deshacen código que ya pasó el loop; su loop es CI verde + CodeRabbit con la regla de §5 + `APPROVE lead <sha>`. §7: no hay cambio de configuración del gateway; los crons se crean y se quitan desde la Mac. **§7, ventana segura:** la condición "ningún cron con `Next` en 15 minutos" se lee **sin contar los tres crons de esta fase** (`corrida-vigia-9`, `corrida-empuje-9`, `corrida-vigia-simulacro-9`): con `corrida-empuje-9` cada 15 minutos la ventana no se abriría nunca. La razón de §7 sigue en pie para los demás: un merge baja al gateway en el siguiente sync y recarga configuración, lo que mata las corridas en vuelo. El comando queda `~/.openclaw/bin/openclaw cron list`, cuya salida de texto trae la columna `Next` en relativo ("in 2h"); con `--json` ese campo se llama `nextRunAtMs` y viene en milisegundos. Se miran los de **todo cron que no sea de esta fase**. **Del plan:** ninguna conocida.

---

## Cola de merge

Cada ítem se mergea por la ruta del kit (loop §6), en ventana segura (loop §7), cuando su loop (§3) está completo. **Compuerta común:** CI verde sobre el SHA final, y `git log origin/main..HEAD` con solo commits de ese carril más, si los hubo, los merges de la regla 7. Las pruebas de cada compuerta se corren **en el worktree del carril**, que es donde está ese SHA.

| # | Qué | Compuerta propia, observable | Si no pasa |
|---|---|---|---|
| **Q1** | PR de N | En `/Users/dn/dev/wt-f9-N`: `bash scripts/tests/test-corrida-nucleo.sh`, `test-corrida-preflight.sh` y `test-cli-modos.sh` terminan en `TODO VERDE`, y **tú** mataste al menos una mutación por tarea (loop §3 paso 3) | Encargo `BRIEF-r<N>.md` a N. Al tercer encargo sin verde, N pasa a `atorado` |
| **Q2** | PRs de M y de P, en el orden en que queden listos | M: `test-corrida-estado.sh` y `test-corrida-latido.sh`. P: `test-corrida-responder.sh` y `test-tmux-activity-watch.sh`, y `git diff --numstat origin/main -- scripts/tests/test-tmux-activity-watch.sh` con la **segunda columna en `0`** (solo agrega casos, no borra ninguno) | Encargo al carril dueño; al tercero sin verde, `atorado`. Uno no espera al otro |
| **Q3** | PR de D | `test-loop-autopilot.sh`, `test-runbooks-no-contradicen-entorno.sh`, `test-skill-autopilot-runbook.sh` y `test-guia-del-vigia.sh` en `TODO VERDE`. Después del merge, desde `wt-f9-lead` al día: `cmp docs/agent-skills/autopilot-runbook/SKILL.md ~/.claude/skills/autopilot-runbook/SKILL.md; echo paridad=$?`; con `paridad` distinto de cero, `cp` del repo a esa ruta | Encargo a D; al tercero, `atorado` |
| **Q4** | Instalación en la Mac y simulacro 9.9 | Sección "Q4", abajo | Sus propias filas |
| **Q5** | PR de cierre, rama `fase9/cierre` | Revisión de cierre (loop §10) contra la DoD literal de cada fila | Se corrige la celda, no la realidad |

### Q4 · Instalación en la Mac y simulacro

**Instalar**, con el código ya en `origin/main`. Va en un subshell con `set -e`: al primer fallo se corta y **no** se toca `launchctl`. Lo que se pisa queda respaldado en `<destino>.f9-previo-<fecha>`. **La reversa que pide loop §7 no es ese respaldo**, que solo sirve de rastro: es volver al contenido de la rama por defecto, que es lo único cuyo origen se puede comprobar. Medido el 2026-09-17: un `<destino>.anterior` de una instalación previa contenía una versión **peor** que la viva, y restaurarlo a ciegas habría degradado la Mac.

```
( set -e
  cd /Users/dn/dev/wt-f9-lead && git fetch origin
  instala() { # $1 ruta en el repo, $2 destino
    git cat-file -e "origin/main:$1" 2>/dev/null || { echo "AUSENTE $1"; return 0; }
    git show "origin/main:$1" > "$2.nuevo"
    [ -s "$2.nuevo" ] && [ "$(git rev-parse "origin/main:$1")" = "$(git hash-object "$2.nuevo")" ] || { echo "FALLO $1"; return 1; }
    [ ! -e "$2" ] || cp -p "$2" "$2.f9-previo-$(date +%Y%m%d%H%M%S)"   # respaldo con fecha: nunca se pisa uno viejo ni se confunde con el de otra instalacion
    chmod +x "$2.nuevo" && mv "$2.nuevo" "$2" && echo "ok $1"
  }
  mkdir -p ~/bin/corrida
  instala scripts/mac/corrida.sh ~/bin/corrida.sh
  for f in lib abrir lanzar-sesion cerrar preflight estado latido responder; do instala "scripts/mac/corrida/$f.sh" ~/bin/corrida/"$f.sh"; done
  instala scripts/mac/cli-modos.tsv ~/bin/cli-modos.tsv
  instala scripts/mac/tmux-activity-watch.sh ~/bin/tmux-activity-watch.sh
  instala scripts/mac/ai.goncloud.corrida-latido.plist ~/Library/LaunchAgents/ai.goncloud.corrida-latido.plist
); echo instalacion=$?
```

`AUSENTE` es lo esperado para los archivos de un carril `atorado` y no corta nada. `instalacion` distinto de cero: fila de atores. Con `instalacion=0`:

```
launchctl kickstart -k gui/501/ai.goncloud.tmux-activity-watch; echo kickstart=$?
n=0; until pgrep -f 'bin/tmux-activity-watch.sh' >/dev/null || [ $n -ge 10 ]; do n=$((n+1)); sleep 1; done
pgrep -f 'bin/tmux-activity-watch.sh' >/dev/null; echo vigilante_vivo=$?
if [ ! -e ~/Library/LaunchAgents/ai.goncloud.corrida-latido.plist ]; then echo latido=ausente
elif launchctl print gui/501/ai.goncloud.corrida-latido >/dev/null 2>&1; then echo latido=ya-cargado
else launchctl bootstrap gui/501 ~/Library/LaunchAgents/ai.goncloud.corrida-latido.plist; echo latido=$?; fi
```

`vigilante_vivo` distinto de cero: el vigilante nuevo no levantó; se restaura desde la rama por defecto con el mismo cuidado que al instalar (`git show origin/main:scripts/mac/tmux-activity-watch.sh > ~/bin/tmux-activity-watch.sh.nuevo`, comparar `git rev-parse` con `git hash-object`, `chmod +x`, `mv`), otro `kickstart`, y 9.6 queda declarada "sin enganche instalado". `latido=ausente`: el carril M quedó `atorado` y no hay latido que cargar; se sigue. `kickstart` distinto de cero, o `latido` con un número distinto de cero: tu host te negó `launchctl`; fila de atores.

**Espera el sync antes de los escenarios 5 y 6.** claw reacciona con las skills y la guía que D mergeó, y esas bajan al gateway con el sync. No se corren antes del primer minuto `:25` de una hora impar, leído con `TZ=America/New_York date '+%H:%M'`, que sea posterior al merge de Q3. **Si D quedó `atorado` no hay nada que esperar**: se corren de inmediato, con las skills que claw ya tenía, y eso se anota junto al resultado. Que el gateway sí las bajó queda `unknown`: la evidencia es lo que claw haga.

**Simulacro**, en este orden, en serie. `--simulacro` y `--cli-modos` quedan **en el registro** (9.2), no en el entorno: por eso los ven igual el vigilante bajo launchd, el latido y claw, que no heredan tus variables. El prefijo `[SIMULACRO] ` lo antepone `corrida_mensaje` a todo mensaje de esa corrida, y el parte de `corrida-vigia-simulacro-9` lo pide en su texto.

```
FX=/Users/dn/dev/wt-f9-lead/scripts/tests/fixtures
A=$(mktemp -d); B=$(mktemp -d); C=$(mktemp -d)
printf 'trabajando\n' > "$A/pantalla.txt"; printf 'trabajando\n' > "$B/pantalla.txt"
printf 'Imprime exactamente esta linea y no hagas nada mas: LISTO 0000000\n' > "$C/ENCARGO.md"
~/bin/corrida.sh abrir simulacro-9 --runbook "$FX/corrida/runbook-simulacro.md" --vigia claw --simulacro --cli-modos "$FX/corrida/cli-modos-simulacro.tsv"
touch ~/.local/state/corridas/simulacro-9/responder.on   # el registro va 700 en el directorio y 600 en sus archivos; si este touch falla, el implementador puso 600 al directorio: corrección tras un merge
~/bin/corrida.sh lanzar-sesion simulacro-9 lead   tui-falso "$B" --nombre sim9-lead
~/bin/corrida.sh lanzar-sesion simulacro-9 carril tui-falso "$A" --nombre sim9-falso
~/bin/corrida.sh lanzar-sesion simulacro-9 carril glm       "$C" --nombre sim9-glm --encargo "$C/ENCARGO.md"
```

Lo que se lee: `~/.local/state/corridas/simulacro-9/decisiones.jsonl` (qué decidió `responder`) y `mensajes.jsonl` (cada mensaje con su hora y el resultado del envío). Cada escenario anota en `docs/evidence/fase9-simulacro-<AAAA-MM-DD>.md` (fecha de inicio, `TZ=America/Los_Angeles date +%F`) la hora del evento, la hora del mensaje y su id. Entre escenarios, la pantalla vuelve a `printf 'trabajando\n' > "$A/pantalla.txt"`.

| # | Cómo se provoca | Qué se espera | Tope |
|---|---|---|---|
| 1 | Ya ocurrió al lanzar `sim9-glm` | Su barra dice `yolo` y su pantalla, leída con `/opt/homebrew/bin/tmux capture-pane -p -t sim9-glm`, trae la línea `LISTO 0000000`. Si M quedó mergeado, además `~/bin/corrida.sh estado simulacro-9` lo da por terminado; con M `atorado`, esa segunda mitad no aplica | 5 min |
| 2 | `cp "$FX/dialogos/confianza.txt" "$A/pantalla.txt"` | `decisiones.jsonl`: acepta, y la tecla salió | 1 min |
| 3 | `cp "$FX/dialogos/permiso-push.txt" "$A/pantalla.txt"` | Ninguna tecla; un `NECESITO TU RESPUESTA` en `mensajes.jsonl`, en lenguaje de usuario | 2 min |
| 5 | `/opt/homebrew/bin/tmux kill-session -t sim9-falso` | El vigilante manda `closed`; claw la relanza con `corrida.sh lanzar-sesion` o dice por qué no | 15 min |
| 6 | `/opt/homebrew/bin/tmux kill-session -t sim9-lead` | claw la relanza leyendo el registro | 15 min |
| 4 y 7 | Si claw no relanzó `sim9-falso` en el escenario 5, la relanzas tú con el mismo `lanzar-sesion` (está preaprobado) y anotas el 5 como "no observado". Después se deja todo quieto | Mensaje por silencio hacia los 30 min, y el latido a los 60 min **contados desde el último mensaje** | 100 min en total |

Un escenario que **se observa y falla** es un hallazgo: si es de una línea, corrección tras un merge (fila de atores) y se repite ese escenario; si no, se declara. **Lo que no se observe se declara "no observado" con su razón; no se cierra en verde** (DoD de 9.9). Al terminar: `~/bin/corrida.sh cerrar simulacro-9`, la comprobación de la regla 5, `cron list --json` sin `corrida-vigia-simulacro-9`, y las sesiones `sim9-…` que sigan vivas se matan.

### Q5 · Cierre

```
cd /Users/dn/dev/wt-f9-lead && git fetch origin
git worktree add /Users/dn/dev/wt-f9-cierre -b fase9/cierre origin/main
mkdir -p /Users/dn/dev/wt-f9-cierre/.saikit/progress /Users/dn/dev/wt-f9-cierre/docs/evidence
cp .saikit/progress/9.json .saikit/progress/9-sesiones.txt /Users/dn/dev/wt-f9-cierre/.saikit/progress/
cp docs/evidence/fase9-spike.md docs/evidence/fase9-simulacro-*.md /Users/dn/dev/wt-f9-cierre/docs/evidence/
```

Celdas `Status`: una tarea con PR lleva `cc:完了 [PR #n, merge <sha>]`; 9.0 y 9.9, que no tienen PR propio, llevan `cc:完了 [evidencia: <ruta>, PR de cierre #n]` (el PR de cierre no puede citar su propio SHA); lo que no se hizo lleva qué quedó y por qué.

Después del merge de cierre, en este orden: quitas **los dos** crons (`~/.openclaw/bin/openclaw cron rm <id>` con cada id de `9-sesiones.txt`, y compruebas que `cron list --json` no trae ningún `corrida-…-9`); desmarcas cada sesión de `9-sesiones.txt` que siga marcada, y la tuya; mandas el mensaje `CERRADA`, en lenguaje de usuario: qué quedó funcionando, qué no y por qué, y **una línea que diga que las respuestas automáticas a los diálogos quedaron apagadas y que encenderlas es decisión suya**; e imprimes `LISTO <sha del merge de cierre>`.

---

## Cuando algo se atora

Las universales están en loop §12. Estas son las de esta fase:

| Situación | Qué haces |
|---|---|
| Una precondición de 0.0 falla en un arranque nuevo | "Toda detención". Con `fase7` distinto de `0`, el mensaje dice: "la Fase 9 no arranca hasta que termine la Fase 7". |
| No estás dentro de tmux (`en_tmux` distinto de cero) | "Toda detención", con `ATORADO lead fuera de tmux`. No marques nada. |
| Sin destino de Telegram (`chat` distinto de cero con el gateway respondiendo) | La fase **sigue**, pero tu seguimiento queda mudo: `message send` exige `-t` (sin él contesta `Missing required option`), así que **ningún** mensaje de la regla 1 puede salir y el único camino es el parte de claw. `corrida-vigia-9` se crea con `--channel last` y sin `--to`. Se declara en el progreso, en el PR de cierre y en el primer parte. |
| `message send` falla | No bloquea: se anota y se reintenta en el siguiente cambio. El parte de claw es un camino independiente. |
| Un `cron add` falla | La fase sigue; se reintenta al abrir M. Si `corrida-empuje-9` nunca entra, tu única red es tu propia espera: se declara. |
| Gateway caído al llegar a Q4 | Esperas armado **dos horas como máximo**. Si no vuelve: se instala igual, el simulacro no corre, 9.9 queda declarada y Q5 sigue. Es distinto de loop §12, porque aquí el gateway solo hace falta para los mensajes. |
| La sesión de un implementador no vive (`viva` distinto de cero) | Corre el binario directo para leer el error. Una recreación; después, siguiente token de la lista. |
| A los 60 s de entregar el encargo la caja sigue vacía y sin actividad | Un `Enter` más ya se mandó (ver "Cómo se lanza"). Reenvías la frase **una** vez. Si tampoco, matas esa sesión (todavía sin contexto) y la recreas; cuenta como la recreación de la fila de arriba. |
| Un implementador pide permiso | Te llega por la línea `[vigia]`. `glm`: `C-c`, 2 s, `C-c` hasta que la pantalla diga `Turn cancelled.`, después `/mode yolo`, comprobar la barra, y "Continúa el encargo donde te quedaste". `muse` y `cursor-agent`: contestas ese diálogo con la tabla de preaprobaciones (lo que no está en la tabla se niega) y, si vuelve a preguntar, relanzas el carril con su flag; ese relanzamiento **no** cuenta como el de loop §12. |
| Hay que **relanzar** a un implementador (calló 30 min, loop §12; o volvió a preguntar tras cambiarle el modo) | Dos sesiones no pueden commitear en la misma rama, así que primero compruebas que de verdad no trabaja: dos `/opt/homebrew/bin/tmux capture-pane -p -t <sesión>` con 60 s de diferencia. Si la pantalla es **idéntica**, está parada y **sí** la matas (cuarta clase de la tabla de preaprobaciones), y relanzas en el mismo worktree con el mismo token y el mismo `BRIEF.md`, con el nombre con sufijo `-b`. Si las pantallas difieren, sigue trabajando: no se relanza y se le dan 2 h más de TIMEBOX. Su línea de `9-sesiones.txt` se **reemplaza**. |
| `muse` muere con `model stream idle timeout` | Cuenta como el relanzamiento único de loop §12. A la segunda, el carril pasa al siguiente token de su lista **y se declara en el PR**: aquí sí se cambia de implementador, porque la causa está medida y no es del encargo. |
| `instalacion` distinto de cero en Q4 | Nada quedó a medias: lo ya movido tiene su `.anterior` y `launchctl` no se tocó. El `<destino>.nuevo` que quede se deja y se declara. Se diagnostica con la línea `FALLO`; si es un archivo que un PR dejó mal, corrección tras un merge; si no se resuelve, Q4 se cierra como "sin instalar", 9.5 y 9.9 quedan declaradas y **Q5 sigue**. |
| Tu host te niega `launchctl` | Mensaje `NECESITO TU RESPUESTA`: en palabras simples, que falta que él active dos piezas en su Mac, y al final los dos comandos. Armas una espera de **60 minutos**; cada 10 compruebas `launchctl print gui/501/ai.goncloud.corrida-latido >/dev/null 2>&1; echo $?` (cero: ya lo corrió). Sin respuesta, Q4 se cierra como "instalado sin activar", 9.5 y 9.9 quedan declaradas, y Q5 sigue. |
| claw no reacciona en los escenarios 5 o 6 dentro del tope | "No observado: claw no actuó", con la hora del evento que sí recibió. No bloquea el cierre. |
| Una ruta de la tabla de worktrees ya existe con trabajo ajeno | No se toca ni se fuerza. Se usa la misma ruta con sufijo `-b` (`wt-f9-N-b`) **solo para worktrees de carril**; `wt-f9-lead` nunca cambia de ruta: si está sucio con algo ajeno es una detención de la fase. |
| **Corrección tras un merge**: la revisión de cierre, un escenario del simulacro, o un carril posterior piden cambiar un archivo de un carril ya mergeado | `git worktree add /Users/dn/dev/wt-f9-fix -b fase9/fix-<carril> origin/main`, encargo al mismo implementador de ese carril, loop §3 **completo**, y se mergea antes de seguir con lo que dependía de eso. Máximo dos por fase; la tercera se declara. |
| **Reversa**: `saikit-postmerge.sh` sale en ROJO | El propio script trae el comando de reversa listo y se usa ese. Si el kit lo rechaza porque el merge ya no es la punta de `main` (pasa: los snapshots la mueven): `git worktree add /Users/dn/dev/wt-f9-revert -b fase9/revert-<carril> origin/main`, `git revert --no-edit <merge_commit>`, PR, el loop reducido de "Desviaciones", y merge por el kit. Los carriles que dependían del revertido se detienen hasta su corrección. |
| La reversa choca o el kit la rechaza dos veces | Segundo intento determinista: en `wt-f9-revert`, `git checkout <merge_commit>^ -- <archivos de la fila del carril>` y commit. Si tampoco entra, es **el único caso que llega a David antes de tiempo**: `NECESITO TU RESPUESTA`, y la fase se detiene. |
| Un commit tuyo sale rojo por el candado de paridad de la skill (`cmp` contra `~/.claude/skills/autopilot-runbook/SKILL.md`) | La copia de la Mac quedó distinta de la rama por defecto, casi siempre porque D editó y luego se atoró. Se restaura con `git show origin/main:docs/agent-skills/autopilot-runbook/SKILL.md > ~/.claude/skills/autopilot-runbook/SKILL.md`, se comprueba con `cmp` y se sigue. Jamás `--no-verify`. |
| El snapshot automático del gateway toca lo mismo que el carril D | Los archivos de `agents/main/agent/workshop-skills/` los reescribe el gateway solo, a los :10 de las horas impares, y **puede revertir lo que D mergeó** (medido: el snapshot `4a7a863` deshizo texto que un PR había puesto ahí). Dos cosas: si el `git merge origin/main` de la regla 7 choca en uno de esos archivos, se resuelve quedándose con la versión del carril (`git checkout --ours -- <archivo>`, que en un merge es tu rama) y se anota; y después del merge de Q3, en el primer `:25` de una hora impar, se comprueba que sigue ahí con `git fetch -q origin && git show origin/main:<archivo> | grep -qF '<una frase que D agregó>'`. **Sin el `fetch` la comprobación es verdadera por construcción**: tu `origin/main` local todavía apunta al merge de Q3. Si el snapshot lo revirtió, es una corrección tras un merge, con el mismo contenido. |
| El tablero no acepta el progreso | Loop §8: se anota una vez, se reintenta en cada cambio. El espejo de la regla 4 no depende del tablero. |
| **Reanudación** (te relanzaron, loop §9) | El estado está en `wt-f9-lead/.saikit/progress/` (progreso, sesiones, ids de cron, hora del último mensaje), en `docs/evidence/` de ese worktree, en los PRs con sus `APPROVE lead <sha>`, y en las sesiones vivas. Entras a `wt-f9-lead` (se reúsa: comprobación de "Dónde te paras"), 0.0 es informativo, repites 0.2 y **reemplazas** la línea `lead` de `9-sesiones.txt`. `/opt/homebrew/bin/tmux ls` para ver qué sigue vivo; en cada sesión, `/opt/homebrew/bin/tmux capture-pane -p -t <sesión> -S -200` y buscar `LISTO <sha>` o `ATORADO`. Compruebas que los dos crons siguen en `cron list --json`; el que falte, lo recreas. No repites trabajo aprobado. |

---

## Inventario y cierre

| | |
|---|---|
| **PRs propios** | Cinco en el camino normal: N, M, P, D y cierre; hasta dos de corrección y uno de reversa. Nunca más de tres abiertos: N solo; luego M y P; luego D; luego cierre. |
| **Implementadores** | Cuatro carriles, de a uno o dos a la vez. |
| **Costo estimado** | 2 a 3.5 millones de tokens del lado del lead, más lo de los implementadores en sus cuentas, más unos 60 turnos cortos de claw por los dos crons. De 10 a 16 horas de reloj: cuatro carriles en tres tandas, más unas 2.5 horas de simulacro. |
| **Presupuesto** | Nada que preparar. Si una cuota se agota, fila de cuota de loop §12. |
| **Una Mac nueva** | Todo lo que esta fase instala vive hoy solo en esta Mac, y el archivo que arranca el vigilante trae `/Users/dn` escrito a fuego. La tarea 9.10 es el instalador que cierra eso; hasta que exista, cambiar de máquina significa rehacer la instalación a mano. |
| **Residuales declarados** | Cuatro lecturas de contexto fresco (2026-09-17) dejaron el documento sin hallazgos que rompan, y estos sin cerrar: el vocabulario de seis palabras del empuje depende de que claw clasifique bien, y una clasificación mala solo cuesta un empuje de más o de menos; `wt-f9-rev` y `wt-f9-lead` son detached, así que su pertenencia se decide por lo que tienen adentro y no por su rama; y la última lectura no volvió a leer el documento completo después de sus propias correcciones. |
| **Fuera de alcance** | Contestar `sí` / `no` al Telegram y que llegue a `responder`; pintar el registro en el tablero de la Fase 7; conectar a Hermes más allá del archivo de eventos; **encender 9.6 para corridas reales**; averiguar por qué el reinicio diario de la sesión de claw no ocurre. |
| **Mensajes a David** | Todos los de la regla 1, más el parte de cada hora, todos en lenguaje de usuario. Es el pedido de la fase. |
| **Cómo termina** | `corrida.sh` y el latido instalados en la Mac; el vigilante reinstalado; 9.6 construida y apagada; loop, skill y guía del vigía al día; `Plans.md` cerrado; los crons `corrida-vigia-9` y `corrida-empuje-9` quitados; todas las sesiones desmarcadas; y tú imprimes `LISTO <sha>`. |

**Cómo se lanza, en una línea:** cuando la Fase 7 esté cerrada, claw elige un lead de su lista de preferencia, lo abre en tmux sobre `/Users/dn/dev/goncloud-openclaw` con el modo de permisos que no pregunta de ese host, y le entrega este archivo con esta instrucción, literal:

> "Abre la sesión con el nombre `<token>-wt-f9-lead` y entrégale este archivo: ejecuta la Fase 9 de `Plans.md` en autopilot siguiendo `docs/runbooks/autopilot-fase9.md` de `origin/main`; tu primer paso es 0.0. Y una regla para ti, claw, durante toda la fase: **las sesiones cuyo nombre contenga `wt-f9-` las contesta su lead, no tú**. Si el vigilante te avisa que una de ellas espera a una persona, no escribas en ella. La única excepción es la que termina en `-wt-f9-lead`, y solo para la línea `[vigia]` del cron `corrida-empuje-9`."
 Si el host del lead necesita un sentinel para que el kit selle (en Claude Code, `-saikit:autopilot` al inicio de la instrucción), la instrucción lo lleva.

*Este archivo es la fuente. Cualquier tablero web es una copia y lo dice en su pie.*
