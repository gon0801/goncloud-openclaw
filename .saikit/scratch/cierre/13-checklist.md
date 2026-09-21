# Cierre Fase 13 — checklist de la revisión de cierre (loop §10)

Borrador preparado el 2026-09-19 (worktree `/Users/dn/dev/wt-f13-lead`, detached en `origin/main`).
Fuentes: `git show origin/main:Plans.md` (sección Fase 13), `gh pr view` de #101/#102/#105
(goncloud-openclaw) y #10 (goncloud-workspace-ingenieria), `.saikit/progress/13.json` (tablero vivo),
`scripts/cierre-de-fase.sh`, `docs/runbooks/autopilot-fase13.md`, `docs/spec/seguimiento.v1.md`.

Estado de la cola al escribir esto (del 13.json): Q0 verificado (5dba1876, PR #99) · Q1 verificado
(9e291ad6, PR #102 = 13.1) · Q2 en_merge (PR #101, pendiente SOLO sello) · Q3 pendiente del sello de A
(PR #10 en ingeniería) · Q4 en_merge (PR #105, pendiente SOLO sello) · Q5 pendiente (cierre).

---

## 1. Filas 13.1 a 13.7

### 13.1 — Marcas de candado declaradas (carril R)

**(a) DoD literal (la celda):**

```
Rojo primero: hoy ninguna de las frases ancladas tiene marca. Mutante que discrimina: quitarle la marca a una frase anclada deja rojo; poner una marca que apunte a un test que no la afirma deja rojo. `bash scripts/run-checks.sh` verde.
```

**(b) Estado conocido:** MERGED. PR #102 (`feat(13.1): marcas de candado declarado`), merge commit
**`9e291ad652dcc6a3f7d57f877809dec62f460004`**. Ya está en `merge_commits` de Q1 del 13.json.
APPROVE lead sobre el head `8e9f740` tras tres rondas de cruzada (LGTM en ronda 3); auditoría con los
dos mutantes de la DoD y tres estilos de ancla (100 frases, 57 marcas).

**(c) Evidencia para `cc:完了`:** ya existe — citar el merge sha `9e291ad6` (PR #102). Nada pendiente
salvo adjudicar los residuales (sección 3).

---

### 13.5 + 13.2 — Dos copias y el sync avisa skills (carril M, PR #101)

**(a) DoD literal (celda de 13.5):**

```
Rojo primero: hoy (a) hace fallar a (b). Mutante: cambiar una palabra de cualquiera de las dos copias deja rojo; agregar un `.txt` nuevo sin `.md` deja rojo. **No se aplica nada al gateway en esta tarea.**
```

**(a) DoD literal (celda de 13.2):**

```
Rojo primero: `scripts/tests/test-sync-avisa-skills.sh` extrae la función entre las marcas, la corre con `pwsh` contra un repo git temporal con un cambio en `agents/x/agent/workshop-skills/s/SKILL.md` y otro fuera de ese directorio, y exige la línea `SKILLS x 1 archivo(s): s/SKILL.md` y ninguna por el de fuera. El mismo test pasa `sync-repos.ps1` entero por `[System.Management.Automation.Language.Parser]::ParseFile` y exige cero errores, y fuerza un error dentro de la función para exigir la línea `SKILLS error:` y que el flujo siga. Si `pwsh` no está, **falla**, no se salta: `ubuntu-latest` lo trae. Mutantes: quitar el llamado desde el flujo de `sync-repos.ps1` deja rojo; moverlo antes de la guardia de tamaño o después del commit deja rojo (estructural, como `test-sync-no-sube-binarios.sh`). El `.post.json` del vigía trae `payload.message` idéntico al `.txt` y `agentId`, `schedule`, `toolsAllow` y `enabled` intactos. Prueba antes del alta, sin esperar a que un agente cambie algo: dos copias one-shot del v2 con `--tools exec`, que hace físicamente imposible el aviso (`docs/crons/verif-sync-repos.md:9-11`), con `LOG=` apuntando a `C:\Users\ehven\.openclaw-state\vigia-sync-prueba\sync-repos.log`. Ese archivo es la cola real del log más una línea `2026-09-19 09:10:00 .openclaw SKILLS verifier 10 archivo(s): …`, el cambio real que subió `43097da`. La primera copia tiene que nombrar a `verifier` y sus archivos, y sacar el porqué del run de `skill-collection-review-verifier` de las 05:59 PDT; la segunda, con la misma copia sin esa línea, tiene que terminar sin nada que avisar por D. Reversa: `cron edit` con el `.pre.json`. Fuera de las ventanas cerradas de `APLICAR_VERIF_20H.sh:7`.
```

**(b) Estado conocido:** PR #101 OPEN, head **`53f2250ad58ff892aa1c18418d14c8a7eb4f66b6`**
(`fase13/vigia`). Checks `quality` y `gate` SUCCESS. APPROVE lead del head `76fd993` y re-APPROVE
del head `53f2250` (regla 5, base al día; los commits del carril son `0b990f3` y `6bfee72`; el resto
del diff es merge de base). Compuerta de gateway completa y verificada por el lead: `payload.message`
del cron vivo `2d763be5` byte-exacto al `v2.txt` con `agentId`/`schedule`/`toolsAllow`/`enabled`
intactos; one-shots D1 (nombra a `verifier` y sus 10 archivos, físicamente sin Telegram por
`--tools exec`) y D2 (callado en D) corridos con `cron run --wait`, borrados y re-lectura fresca
idéntica. Evidencia `.runs.json` en `.saikit/scratch/M/`. Pendiente SOLO de sello (caída transversal
de hooks en sesiones nuevas desde ~23:10 PDT).

**(c) Evidencia para `cc:完了`:**
1. Sello → merge en ventana segura → **citar el merge sha de #101**.
2. Verificar presencia en `origin/main` de `docs/cron-messages/backup/2d763be5-*` (`.pre.json` y
   `.post.json` del aplicador real, commit `6bfee72`; HOY no están en `origin/main`, llegan con este
   merge). En Q5 solo se verifica presencia, no se re-tocan.
3. La evidencia D1/D2 real ya vive en `.saikit/scratch/M/` (citada en el re-APPROVE); el PR de cierre
   puede citarla tal cual.

---

### 13.3 + 13.4 — Candado de comportamiento de verify y drive del merge-guard (carril V, PR #105)

**(a) DoD literal (celda de 13.3):**

```
Rojo primero pegado en `.saikit/scratch/V/tdd.md`: contra `origin/main` sin tocar, el test falla por las cinco. Verde después. Tres mutantes: cambiar una letra de un `blockReason` en `index.ts` deja rojo; agregar un guard numerado sin ponerlo en la lista deja rojo; poner una ruta `/Users/dn/` en la lista de (c) deja rojo en CI. `bash scripts/run-checks.sh` verde.
```

**(a) DoD literal (celda de 13.4):**

```
Mutante con la sustitución escrita: reemplazar `lib.ts:214` por `const allowlisted = false;` deja el driver **verde hoy** y **rojo después**, en los casos `implementer pasa` e `ingenieria pasa`; la sustitución `= true` ya deja rojo hoy y por eso no sirve como mutante. Salida `DRIVE VERDE: 10 casos` pegada en el PR. El test pasa igual corriendo después de `node --test`, que borra el enlace.
```

**(b) Estado conocido:** PR #105 OPEN, head **`5fdc4e45c3e89afa022926d138c71467d0ff2d3a`**
(`fase13/verify`). Cruzada cerrada con **LGTM** (dos rondas de fix: symlink preexistente restaurado y
blidado, `ef16bc4` y `5fdc4e4`). CI success. APPROVE lead sobre `5fdc4e4`. `DRIVE VERDE: 10 casos`
(6 bloqueados, 4 permitidos) declarado en el APPROVE; `run-checks.sh` TODO VERDE sobre el head.
Pendiente SOLO de sello (mismo bloqueo transversal que Q2).

**(c) Evidencia para `cc:完了`:**
1. Sello → merge en ventana segura → **citar el merge sha de #105**.
2. Confirmar que el PR trae (o cita) el rojo primero de 13.3 pegado en `.saikit/scratch/V/tdd.md` y la
   salida `DRIVE VERDE: 10 casos` — ambas exigidas por la DoD literal.

---

### 13.6 — El contrato de ingeniería dice lo que el código hace (carril A, PR #10 en el otro repo)

**(a) DoD literal (la celda):**

```
Rojo primero en `goncloud-workspace-ingenieria`, contra su `AGENTS.md` de `origin/master`. Dos mutantes: volver a poner `main-merge` entre los anti-jobs deja rojo; quitar la frase deja rojo. `bash tests/run.sh` de ese repo verde, y su CI verde.
```

**(b) Estado conocido:** PR #10 OPEN en **gon0801/goncloud-workspace-ingenieria**, head
**`2ecdfb589fbee4d2b3c366ec34a4ffd62d66c8cd`** (`fase13/contrato`). Compuerta de Q3: `bash tests/run.sh`
verde (3/3), CI `tests` pass, cruzada ronda 1 sin bloqueantes, auditoría del lead con las dos
mutaciones de la DoD (restauradas idénticas con `cmp`). APPROVE lead publicado sobre `2ecdfb5`.
Pendiente SOLO del sello EN ESE REPO (el 13.json lo declara "atorado" por el sello; ojo: el campo
`approve_lead` del carril A quedó `null` en el json pese al APPROVE publicado — el json está una ronda
atrás en ese campo; el PR de cierre escribe el json final y lo corrige). Este repo no cambia en 13.6 y
`cierre-de-fase.sh 13` no mira el otro repo: la evidencia del merge se cita, no se recomputa.

**(c) Evidencia para `cc:完了`:**
1. Sello en ese repo → merge en ventana segura de ESE repo (`merge_despliega: publica` también ahí) →
   **citar el merge sha del PR #10 de goncloud-workspace-ingenieria** en la revisión de cierre.
2. Rama `fase13/contrato` de ese repo: borrarla tras el merge (el check de ramas de este script no la
   ve, pero el base la exige igual — el atore de Fase 13 fila "Borrar ramas y worktrees del plan").

---

### 13.7 — Cierre (carril cierre)

**(a) DoD literal (la celda):**

```
`bash scripts/cierre-de-fase.sh 13` en VERDE, incluidos los checks de ramas y worktrees, que hoy salen rojos por la propia rama de planificación. Tras el sync, el SHA del clon del gateway iguala el mergeado y `sync-repos.log` sin `CONFLICTO` ni `FALLO`. Un solo Telegram de cierre.
```

**(b) Estado conocido:** pendiente (Q5). Es la propia revisión para la que este checklist prepara.
Contenido de la fila: rama `fase13/cierre` desde `origin/main`; celdas Status; `.saikit/progress/13.json`;
`docs/evidence/fase13-lectores-frescos.md` (ya está en `origin/main`, llegó con la reescritura del plan)
y el `.post.json` del vigía (`2d763be5-…`, llega con el merge de #101). Borrar la rama y el worktree del plan.

**(c) Evidencia para `cc:完了`:** ver sección 2 (artefactos) y 4 (compuertas). Puntos de adjudicación
que la DoD literal plantea y el runbook matiza:
- **Igualdad de SHA tras el sync**: la DoD pide "el SHA del clon del gateway iguala el mergeado"; el
  runbook (fila Q5) declara el residual: basta con que el mergeado sea **ancestro** de la punta del
  clon (el snapshot de cada ciclo mueve la punta); el residual se declara en el PR de cierre.
- **Los checks de ramas y worktrees salen rojos por la propia rama de planificación**: el VERDE final
  solo es posible DESPUÉS de borrar la rama de cierre y su worktree (y los del plan); se corre el
  script una vez borrados, desde fuera (el atore fila 103 del runbook trae la receta).

---

## 2. Artefactos de cierre que exige el base

1. **Celdas Status de Plans.md con el token literal `cc:完了`** (hoy las 7 filas dicen `cc:TODO`).
   El carril cierre solo puede tocar `Plans.md` en las celdas Status. El check `plan` de
   `cierre-de-fase.sh` cuenta rojas por `cc:(TODO|WIP)` en la última columna.
2. **`.saikit/progress/13.json` final** en el PR de cierre: `cierre.at`, `cierre.telegram_message_id`,
   `cierre.resumen`, carriles en estados terminales, cola Q1–Q5 `verificado`, `atencion_requerida`
   en false. HOY NO está trackeado (`git ls-files .saikit/progress/` solo trae 12.json, 7.json,
   fase6.json): el PR de cierre lo AGREGA a git (`.saikit/` no está ignorado en este repo). Debe
   coincidir con el tablero vivo: el check `tablero` compara fase/cierre.at/título/siguiente_paso/
   atencion/carriles del versionado contra `runbook.progress.get` del gateway.
3. **`.saikit/progress/13-sesiones.txt`** también entra al PR de cierre (hoy untracked). Contenido
   actual: `lead - glm-wt-f13-lead`, `R glm glm-wt-f13-R-b`, `M cursor-agent cursor-agent-wt-f13-M`,
   `A muse muse-wt-f13-A`, `V glm glm-wt-f13-V`.
4. **`docs/evidence/**`**: `fase13-lectores-frescos.md` ya vive en `origin/main`; evidencia nueva de
   la revisión de cierre (si la hay) va aquí. Es ruta permitida del carril cierre.
5. **`docs/cron-messages/backup/**`**: `.post.json` del vigía `2d763be5` — llega con el merge de #101;
   en Q5 SOLO se verifica presencia en `origin/main`, no se re-toca.
6. **Telegram CERRADA — el ÚNICO mensaje a David de la fase**: forma `CERRADA` de
   `docs/spec/seguimiento.v1.md`, con `--silent`, una sola vez, LO ÚLTIMO (tras el VERDE del script).
   Al progreso solo `cierre.telegram_message_id` (campo `messageId` del `--json` del envío).
   `CHAT` se lee del `cron list` (vale `6470689715` hoy; se lee, no se pega). Si el envío falla: dos
   reintentos, y si no sale, se cierra con `telegram_message_id: null` y el error declarado en PR y
   progreso.

**Reglas de tiempo del spec, textuales** (seguimiento.v1.md, para no rebuscarlas):

> "Tope: un `AVANZA` a menos de 15 minutos del anterior se junta con el siguiente cambio; las otras
> tres salen siempre de inmediato. Rutina con `--silent`; `NECESITO TU RESPUESTA` con notificación."

> "En `CERRADA` basta un cierre en palabras: ya no queda nada que contar."

**OJO — franjas de silencio:** `seguimiento.v1.md` NO define franjas de silencio para el Telegram del
lead; sus únicas reglas de tiempo son las dos citas de arriba. Las franjas de silencio que sí existen
en el ecosistema, textuales y con fuente, por si el cierre las cruza:
- Vigía `verif-sync-repos` (Plans.md 13.2 y `docs/crons/verif-sync-repos.md:36`, CASO C):
  > "En la franja de silencio de 23:00 a 08:00 CDMX no avisa, sin excepción: lo diferido sale junto en
  > el primer aviso de la mañana." / "respetar el silencio de 23:00 a 08:00 CDMX, con UNA excepcion:
  > si el problema lleva mas de 6 horas, avisar igual (a esa altura ya se perdieron 3 ciclos)."
- Ventanas cerradas del aplicador (`APLICAR_VERIF_20H.sh:7`):
  > "Ventanas cerradas (corridas de negocio): 12:55-13:35Z (7h) 16:55-17:25Z (11h) 01:55-02:25Z (20h)."
- Ventana segura de MERGE (`docs/runbooks/base-openclaw.md:207`), aplica a #101, #105 y #10:
  > "ningún cron con `Next` en los próximos 15 minutos, y **fuera de los minutos :05 a :15 de las
  > horas impares**" en `America/New_York` (el sync corre a los :10 de las horas impares).

---

## 3. Residuales declarados en los APPROVEs (adjudicar contra la DoD literal)

### PR #101 (13.5 + 13.2) — APPROVE sobre `76fd993` y re-APPROVE sobre `53f2250`
1. `test-aplicar-vigia-sync-prueba.sh` deja seis `.pre.json/.post.json` de ejemplo (untracked) en
   `docs/cron-messages/backup/` tras correr: "limpiables en el cierre". **Adjudica en 13.7**:
   `docs/cron-messages/backup/**` es ruta permitida del carril cierre — limpiarlos o declararlos en el
   PR de cierre. No toca ninguna DoD de 13.5/13.2.
2. La prueba real D1/D2 contra el gateway corrió en la compuerta de Q2, no en el PR. **Cerrado por el
   re-APPROVE**: compuerta ejecutada y verificada (mensaje byte-exacto, one-shots corridos y borrados,
   re-lectura idéntica; evidencia `.saikit/scratch/M/`). La DoD de 13.2 exigía esa prueba antes del
   alta: satisfecha.
3. Cruzada final: un hallazgo sobre `tablero-runbook/index.ts` que NO es del PR (entró por el merge de
   base desde `05dadc3`, historial de main). **Queda como fila futura del plan**, no bloquea, no es de
   la fase.
4. CodeRabbit sin cuota ("Review rate limited"), declarado por loop §5.

### PR #102 (13.1) — APPROVE sobre `8e9f740`
1. `test-tmux-activity-watch.sh` es flaky (fila 9.13 del plan, **preexistente**, no lo trae el diff):
   un rojo, cinco verdes. Preexistente y ajeno a la DoD de 13.1 → no adjudica en Fase 13.
2. La auto-prueba de regresión (caja de arena mktemp) suma tiempo a la batería si el log del repo
   crece (medido: despreciable hoy). Nota, sin acción.
3. CodeRabbit: el APPROVE no lo declara; el 13.json dice "sin cuota (rate limited), declarado" (hay un
   comentario de coderabbitai con 6 hallazgos, todos sobre `.saikit/scratch/R/colocar.py` — scratch,
   no producto). Sin impacto en la DoD.

### PR #105 (13.3 + 13.4) — APPROVE sobre `5fdc4e4`
1. "Residuales no bloqueantes: ninguno nuevo." CodeRabbit sin cuota, declarado por loop §5. La DoD
   (mutantes, `DRIVE VERDE: 10 casos`, `run-checks.sh` verde) satisfecha según auditoría del lead.

### PR #10 de goncloud-workspace-ingenieria (13.6) — APPROVE sobre `2ecdfb5`
1. El anti-ancla del test solo prohíbe formas de infinitivo («mergear»); una conjugada
   («Mergea a main cuando quieras…») pasaría el ancla. **Fila futura de endurecimiento**: los dos
   mutantes de la DoD mueren igual, así que la DoD literal de 13.6 queda satisfecha.
2. `TEST_REF=WORKTREE` lee el worktree sucio (el hook heal-repo agrega un bloque a `AGENTS.md` al
   abrir sesión); el modo HEAD — el que corre batería y CI — no se afecta. Sin impacto en la DoD.
3. CodeRabbit sin cuota, declarado, no bloquea (loop §5).

---

## 4. Compuertas de `bash scripts/cierre-de-fase.sh 13` (todo debe salir VERDE, salida 0)

| Check | Qué exige | Qué falta hoy |
|---|---|---|
| plan | 7 filas 13.x con Status sin `cc:(TODO\|WIP)` | Las 7 en `cc:TODO` |
| ramas | Ninguna rama que matchee `(^\|/)fase13(/\|$)\|fase13-` ni en remoto ni local | Borrar (remoto+local): `fase13/marcas`, `fase13/vigia`, `fase13/verify` tras sus merges, `fase13/cierre` al final, `docs/plan-fase13-candados-contratos`, `docs/fase13-aviso-del-sync` (local; nunca se pusheó — si el remoto dice que no existe, se sigue). La rama `docs/runbook-fase13` NO se borra y el regex no la matchea |
| worktrees | Ninguno que matchee `f13-\|fase13` | Quitar todos los `wt-f13-*`: lead, R-b, M, V, A, cierre, y los del plan (`wt-f13-docs`, `wt-f13-aviso`) — incluido el propio `wt-f13-lead` |
| sesiones | Ninguna sesión tmux de la fase con `OPENCLAW_WATCH=1` | Desmarcar las cinco de `13-sesiones.txt` |
| despliegue | Plugins declarados en el bloque de la fase | La fase no declara `plugin …` → VERDE directo |
| tablero | 13.json versionado == tablero vivo (carriles terminales, `cierre.at`, sin atención) | 13.json actual tiene carriles `en_pr`/`atorado` y `cierre.at: null` |
| ci | Última corrida de CI en `main` = success | Se cumple al cerrar (main está verde) |

Más la compuerta del sync (DoD 13.7): tras un ciclo de sync, el SHA mergeado **ancestro** de la punta
del clon del gateway y `sync-repos.log` sin `CONFLICTO` ni `FALLO` (la punta NO tiene que igualar: el
snapshot la mueve; residual declarado en el PR).

Orden del final: merges Q2/Q3/Q4 en ventana segura → rama `fase13/cierre` con celdas + 13.json +
13-sesiones.txt + evidencia → PR con loop reducido → merge en ventana segura → ciclo de sync y
compuerta del sync → borrar ramas y worktrees (incluida la de cierre) → `cierre-de-fase.sh 13` VERDE
con salida 0 → **Telegram CERRADA, lo último** → `messageId` al progreso.

---

## 5. Lo que falta, en cinco líneas

1. Sello y merge de Q2 (PR #101, head 53f2250): todo verificado salvo el sello; su merge trae además
   el `.post.json` del vigía a `origin/main`.
2. Sello y merge de Q4 (PR #105, head 5fdc4e4): LGTM, CI y APPROVE listos, mismo sello pendiente.
3. Sello y merge de Q3 (PR #10 en goncloud-workspace-ingenieria, head 2ecdfb5): APPROVE puesto ahí,
   sello en ese repo; el 13.json debe además corregir `approve_lead` del carril A.
4. Q5 entero: celdas Status a `cc:完了`, 13.json final con `cierre.at`/`telegram_message_id` (hoy
   ni 13.json ni 13-sesiones.txt están trackeados), limpieza de ramas/worktrees/sesiones, compuerta
   del sync y `cierre-de-fase.sh 13` en VERDE.
5. El único Telegram `CERRADA` (forma de seguimiento.v1, `--silent`) como último acto; residuales a
   adjudicar: seis `.pre/.post.json` untracked del backup (limpiar o declarar) y el matiz de
   igualdad-de-SHA (ancestro basta, residual en el PR).
