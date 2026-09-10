# Brief para Grok — reconciliar el repo del gateway (bloqueo unico)

Fecha: 2026-09-10 ~18:20Z. Lead: Claude (planea y revisa, no aplica). Implementa: Grok (infra/ops).
Maquina: **Windows del gateway** (`C:\Users\ehven\.openclaw`). Todo este trabajo se hace ahi.

## 0. El problema, con evidencia

El repo del gateway lleva horas sin sincronizar y **nadie se habia enterado**, porque el sync falla en silencio.

- El checkout de Windows esta en una rama local llamada **`Principal`**.
- **`origin/Principal` NO existe.** El remoto solo tiene: `main`, `chore/fase-b-evidencia`, `fix/agentes-openclaw`, `fix/crons-bugs-silenciosos`.
- Por eso `scripts/sync-repos.ps1` registra, cada ciclo:
  ```
  2026-09-10 13:10:07  .openclaw CONFLICTO en pull - se deja como estaba, revisar a mano
  2026-09-10 13:10:08  .openclaw push FALLO
  ```
  (Los otros 3 repos — `workspace`, `workspace-ingenieria`, `workspace-operaciones` — sincronizan bien. El unico roto es el del gateway.)
- Ancestro comun con `main`: `61b2d2a` (auto snapshot 03:10). Desde ahi:
  - `Principal` tiene 2 commits locales: `20d8eb3` (05:10) y `f511b2c` (13:10), ambos auto-snapshots.
  - `main` tiene los merges de hoy: PR #1 y #3 (Muse, crons de packing) y **PR #2 (Cursor, workspaces de los 4 agentes + summa-gate)**. Head: `2862018`.
- Ademas hay cambios sin commitear: `M openclaw.json` (la config de modelos aplicada hoy).

**Consecuencias medidas:**
1. El trabajo de Cursor nunca llego a los agentes. Verificado: `findstr "Dos maquinas" workspace-reviewer\AGENTS.md` no encuentra nada. Los 4 agentes de pipeline siguen con IDENTITY sin llenar, USER con directiva placeholder activa, y AGENTS.md nombrando herramientas que en OpenClaw no existen.
2. Como el push tambien falla, **la config de modelos arreglada hoy no esta respaldada en ningun lado**: vive solo en ese disco.

## 1. La regla que no se puede equivocar

**`openclaw.json` LOCAL gana. Todo lo demas viene de `main`.**

Motivo, verificado: el `openclaw.json` que esta en `origin/main` es el **viejo**, de antes de los arreglos de hoy:

| agente | en `main` (viejo) | en el disco (correcto, verificado hoy) |
|---|---|---|
| reviewer | `openai/gpt-5.5-pro` | `kimi/k3` |
| adversary | `openai/gpt-5.5-pro` | `deepseek/deepseek-v4-flash` |
| ingenieria | `openai/gpt-5.3-codex-spark` | `xai/grok-4.6` |
| implementer | `openai/gpt-5.5` | `zai/glm-5.3` |
| verifier | `openai/gpt-5.6-luna` | `deepseek/deepseek-v4-flash` |

El perfil de OpenAI esta **en cooldown 4 dias** (lo reporto `openclaw doctor`). Si la version de `main` gana, `reviewer` y `adversary` vuelven a quedar con las 3 cadenas apuntando a un proveedor bloqueado — que es exactamente el estado en que llevaban **cero corridas completadas** esta mañana.

**Y el guard del sync NO te protege de eso**: `sync-repos.ps1` revierte el pull solo si `openclaw config validate` falla. La config vieja es *valida*, solo esta *muerta*. Pasaria el guard sin problema.

## 2. Guardrails

1. **Backup antes de tocar git**: copia de `openclaw.json` fuera del repo + `git branch backup/principal-20260910` sobre el estado actual. Sin eso, no empieces.
2. **Ventana**: el proximo cron de negocio es `packing-digest-20h` a las 02:00Z (20:00 CDMX). Hay ~8 h. No trabajar dentro de +/-30 min de esa hora.
3. **No reiniciar el gateway** durante la reconciliacion (produce `admitted run authority is no longer active` en corridas activas). Si hace falta reinicio, es paso aparte y declarado.
4. **No tocar los crons de packing** (`Packing extras 7AM`, `Packing extras 11AM`, `packing-digest-20h`). Hoy corrieron los tres en `ok`.
5. **No tocar `channels.telegram.defaultAccount`**. La cuenta `default` es el bot de Claw (aparece en su sessionKey `agent:main:telegram:default:...`); esta configurada a la vieja usanza y funciona. La advertencia de `doctor` sobre eso es cosmetica: "arreglarla" moveria el unico chat que usa David.
6. Verificar con **llamada real**, no con la config: que un modelo aparezca en `models list` no prueba que responda.

## 3. Trabajo

### Paso 1 — Fotografia y respaldo
Registrar y guardar antes de cambiar nada: rama actual, `git status --porcelain`, `git log --oneline -5`, y el `openclaw.json` vigente (copia fisica fuera del repo). Crear `backup/principal-20260910`.

### Paso 2 — Commitear el estado vivo
`openclaw.json` esta modificado sin commitear. Commitearlo en `Principal` para que la reconciliacion sea entre commits y no entre "commit vs working tree".

### Paso 3 — Traer `main` conservando la config local
Traer `origin/main` sobre `Principal` resolviendo **`openclaw.json` a favor del lado local** y aceptando de `main` todo el resto (los 4 `workspace-*`, `summa-gate/`, `docs/`, `scripts/`).
Decidi el metodo vos (merge con resolucion dirigida, o traer main y restaurar el archivo desde el backup): el requisito es el resultado, no la tecnica. Lo que NO se acepta es un resultado donde `openclaw.json` quede con los primarios de OpenAI.

### Paso 4 — Dejar la rama donde el sync la encuentre
El script hace `git pull/push origin <rama actual>`. Mientras la rama se llame `Principal` y no exista en el remoto, el sync seguira fallando en cada ciclo.
Opciones (elegi y justifica): renombrar la rama local a `main` y alinearla con `origin/main`, o publicar `Principal` y cambiar el default del repo. **Preferencia del lead: quedar en `main`**, que es donde apuntan los PRs y el resto del flujo.

### Paso 5 — Verificacion (esto es la entrega, no los pasos)
1. `git status` limpio y `git log` mostrando los merges de hoy (`2862018` alcanzable).
2. **Config intacta**: `openclaw config get agents.entries.reviewer.model` devuelve `kimi/k3` — no `openai/gpt-5.5-pro`.
3. **Llamada real**: un dispatch a `reviewer` responde con `winnerProvider: kimi` y `fallbackUsed: false`.
4. **El trabajo de Cursor aterrizo**: `findstr /C:"Dos maquinas" workspace-reviewer\AGENTS.md` encuentra la linea; `workspace-reviewer\IDENTITY.md` ya no tiene placeholders; ya no existe `BOOTSTRAP.md` en los 4 workspaces.
5. **El sync vuelve a funcionar**: esperar un ciclo y confirmar en `logs\sync-repos.log` que `.openclaw` registra `pull` y `push ok`, sin `CONFLICTO`.
6. Los 3 crons de packing siguen listados con su `Next` correcto.

## 4. Entrega

Tabla de: paso → que se hizo → evidencia (salida pegada). Mas: metodo elegido en el paso 4 y por que; cualquier cosa que no se pudo verificar, marcada explicitamente; y si hubo que desviarse del brief, decirlo.

Sin narrativa y sin diario de sesion.
