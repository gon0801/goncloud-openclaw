---
name: encargo-cli
description: Úsala cuando David te pida trabajo en un repo de la Mac (implementar, arreglar o revisar), por ejemplo "agrega X en ~/dev/<repo>" o "revísalo con deepseek". Encargas el trabajo a un CLI de la Mac por la ruta gestionada (brief.py, managed_tasks_submit, managed_tasks_admit), terminas tu turno, y R te despierta con el resultado para que lo cierres.
---

# Encargo a la Mac

R lleva el encargo: tú lo registras y lo admites, un host de la Mac se lo entrega a opencode, y el resultado te llega solo, como un turno nuevo en esta misma sesión. No vigiles, no esperes con `sleep` y no teclees en la Mac.

## El alias elige el modelo

| David pide | `--adapter` |
|---|---|
| nada, o "glm" | `opencode` (GLM 5.3 flash, plan de Z.AI) |
| "deepseek" | `opencode@opencode-go/deepseek-v4-pro` |
| "kimi" | `opencode@opencode-go/kimi-k3` |
| "grok" | `opencode@opencode-go/grok-4.7` |
| "qwen" | `opencode@opencode-go/qwen3.8-max` |

Si pide otro modelo, dile que no tiene alias; no inventes uno. Cada alias necesita su host corriendo en la Mac, y eso no lo ves tú.

## Encargar

1. Un trabajo sobre un repo (implementar, arreglar o revisar) parte de su HEAD. Léelo con `exec` en la Mac (`host="node"`, como en `mac-tmux-control`): `/usr/bin/git -C /Users/dn/dev/<repo> rev-parse HEAD`. Las rutas son de la Mac: allá `~` es `/Users/dn`, no el `/Users/gon` de la Mini.
2. Escribe el brief con tu `exec` en la Mini:
   ```
   python3 ~/.local/share/agent-work/brief.py --root /Users/gon/.openclaw/workspace/managed-instructions --host mac-local --adapter <alias> <<'BRIEF'
   <qué hacer, en qué repo (ruta absoluta de la Mac), qué no tocar, si hace commit o no>
   Entrega el resultado ready.v1 con typedPayload {"evidenceRef": "<archivo>"} y el artefacto <archivo>, como lo explica el archivo de asignación (campo protocol).
   BRIEF
   ```
   `<archivo>` es la ruta, relativa al repo, del archivo que prueba el trabajo (por ejemplo `saludo.py`); escríbela, no dejes `<archivo>`. Para una revisión, el resultado es `review.v1` con typedPayload `{"verdict": "approved", "evidenceRef": "<archivo>"}` o `{"verdict": "changes", "findingsRef": "<archivo>"}`. `brief.py` imprime una línea JSON, `{"instructionRef": {"digest": "sha256:…", "ref": "artifact:…"}, "target": {"adapterId": "<alias>", "hostId": "mac-local", "kind": "cli"}}`: copia esos dos objetos tal cual.
3. `managed_tasks_submit` con un `taskKey` nuevo (nunca `key`), por ejemplo `canario-saludo-202610121530` (repo, tema, fecha y hora), y este `assignment`:
   - `target` e `instructionRef`: los de `brief.py`.
   - `inputRevision`: `{"kind": "code", "repository": "/Users/dn/dev/<repo>", "sha": "<HEAD>"}`. Solo un trabajo sin repo (por ejemplo, un archivo suelto) usa `{"kind": "artifact", "ref": <instructionRef.ref>, "digest": <instructionRef.digest>}`.
   - `resultContract`: `ready.v1` para implementar o arreglar, `review.v1` para revisar.
   - `continuation`: `{"kind": "requester"}`.
   - `progressBinding`, solo si el trabajo tiene corrida en el tablero (`seguimiento-tablero`): `{"publisherHostId": "mac-local", "corrida": "<c>", "carril": "<carril>", "intento": "<intento>", "ronda": 1}`.
4. `managed_tasks_admit` con el `taskId` y `admissionKey` `<taskKey>-admit`. Contesta `host-pending`.
5. Termina tu turno. A David dile en una línea el `taskId` y el alias.

## Cuando R te despierte

1. `managed_tasks_inspect` con el `taskId`.
2. Si hay resultado (`result.kind` `produced`), léelo con `managed_tasks_artifact_read` (`offset` 0, `length` 4096, en base64; sigue hasta `eof`) y compruébalo en la Mac (el archivo, el commit).
3. Ciérralo con `managed_tasks_resolve`, que lleva solo `receipt` y `decision` (sin `taskId` aparte). El `receipt` es el `resultReceipt` del inspect, tal cual (`taskId`, `generation` y `resultDigest`). La `decision` es una de estas:
   - `{"kind": "complete", "evidenceRef": "<result.payload.evidenceRef>"}` si cumple;
   - `{"kind": "continue", "children": [{"slot": "correccion-1", "assignment": {...}}]}` si hay que corregir, con un brief nuevo de `brief.py` y el mismo `target`.
4. Cuéntale a David el resultado en pocas líneas.

## Trampas

- `resolve` necesita un resultado. Una tarea que solo tiene una incidencia no se resuelve: se cancela con `managed_tasks_cancel` (`taskId` y `reason`).
- Nunca apruebes una incidencia `permission-required`, ni tú ni pidiéndolo en la Mac. Cancela la tarea y dile a David qué permiso pidió.
- Con `delivery-unaccepted` o `transport-unavailable`, no reenvíes ni teclees en la Mac. Inspecciona y decide; si hay que repetir, es un encargo nuevo con otro `taskKey`.
- Un `taskKey` ya usado con otro brief da `Managed task registration conflict`.
- Si `admit` contesta `Managed CLI host adapter is not certified`, ese alias no está abierto en R. Dile a David cuál.
- Si David pregunta y, después de varios minutos, `managed_tasks_inspect` sigue sin `result` y sin `incidents`, ningún host corre para ese alias. Dile a David qué alias no tiene host; no lo reintentes.
- El CLI trabaja dentro del workspace de su host. Si el repo queda fuera, llega una incidencia de permiso: cancela y dile a David el repo y el alias.
- Encarga desde tu sesión, nunca desde un turno `isolated` de cron: R lo rechaza.
