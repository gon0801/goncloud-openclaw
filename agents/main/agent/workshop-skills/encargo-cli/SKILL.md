---
name: encargo-cli
description: Úsala solo cuando David diga "por CLI" en un pedido de trabajo sobre un repo de la Mac (implementar, arreglar o revisar), por ejemplo "agrega X en ~/dev/<repo>, por CLI con glm 5.3". Sin "por CLI" no es esta skill, aunque nombre un modelo. Ese pedido sigue agent-dispatch.
---

# Encargo a la Mac

R lleva el encargo. Tú lo preparas, lo registras y lo admites. El host de la Mac abre opencode con el modelo pedido, y el resultado te llega solo, como un turno nuevo en esta misma sesión. No vigiles, no esperes con `sleep` y no teclees en la Mac.

Esta ruta entra solo con "por CLI". Si David no lo dijo, no encargues por aquí aunque nombre un modelo. Sigue `agent-dispatch`.

"Por CLI" siempre es un encargo registrado en R, aunque el trabajo sea de una línea. No lo hagas tú con `exec`, `write` ni `edit`. En esta skill tu `exec` corre solo `encargo.py` en la Mac y `brief.py` en la Mini. Un "hecho por CLI" sin `taskId` es falso.

No hay tabla de modelos en esta skill. Qué modelos existen, cuáles están permitidos y cómo cobran lo contesta la Mac.

## Encargar

1. Prepara el encargo con `exec` en la Mac (`host="node"`). `--modelo` lleva las palabras de David, por ejemplo `"glm 5.3 highspeed"`; omítelo si no nombró modelo. La ruta del repo es la de la Mac y va absoluta: allá `~` es `/Users/dn`, no el `/Users/gon` de la Mini. Un trabajo sin repo va sin `--repo`.
   ```
   python3 /Users/dn/dev/wt/agent-work-host/scripts/agent-work/encargo.py preparar --repo /Users/dn/dev/<repo> --modelo "<lo que dijo David>"
   ```
   Contesta una línea JSON. Un rechazo sale con código 3 y aun así trae su línea: léela.
   - Con `"ok": true`, guarda `modelo`, `cobro`, `inputRevision`, `briefArgs` y `enFila`:
     ```
     {"ok": true, "modelo": "zai-coding-plan/glm-5.3-highspeed", "cobro": "subscription", "inputRevision": {"kind": "code", "repository": "/Users/dn/dev/<repo>", "sha": "<HEAD>"}, "briefArgs": ["--host", "mac-local", "--adapter", "opencode", "--model", "zai-coding-plan/glm-5.3-highspeed"], "enFila": false, "host": {"politica": "…", "cli": "…"}}
     ```
   - Con `"ok": false` llegan `causa`, `frase`, `accion` y `candidatos`. Dile a David la `frase` tal cual y haz la `accion`. `no-registrar` significa que aquí termina: no hay tarea. Pasa, por ejemplo, cuando el proveedor está cerrado, o cuando está permitido y David todavía no inició sesión en opencode: la `frase` le dice qué correr. `preguntar-a-david` trae `candidatos`: pregúntale cuál y repite este paso con el id exacto en `--modelo`.
   - Sin línea JSON no hay tarea. Con código 1, opencode o git no contestaron a tiempo y el motivo está en stderr. Si el `exec` mismo falla, la Mac no responde. Díselo a David y termina.
2. Escribe el brief con tu `exec` en la Mini. `<briefArgs>` son los elementos de `briefArgs` del paso 1, en ese orden, separados por espacios y sin cambiar ninguno:
   ```
   python3 ~/.local/share/agent-work/brief.py --root /Users/gon/.openclaw/workspace/managed-instructions <briefArgs> <<'BRIEF'
   <qué hacer, en qué repo (ruta absoluta de la Mac), qué no tocar, si hace commit o no>
   Entrega el resultado ready.v1 con typedPayload {"evidenceRef": "<archivo>"} y el artefacto <archivo>, como lo explica el archivo de asignación (campo protocol).
   BRIEF
   ```
   `<archivo>` es la ruta, relativa al repo, del archivo que prueba el trabajo (por ejemplo `saludo.py`). Escríbela, no dejes `<archivo>`. Para una revisión, el resultado es `review.v1` con typedPayload `{"verdict": "approved", "evidenceRef": "<archivo>"}` o `{"verdict": "changes", "findingsRef": "<archivo>"}`. `--model` hace que `brief.py` escriba el modelo al inicio del brief, que es de donde lo lee el host: no lo escribas tú en la prosa. `brief.py` imprime una línea JSON, `{"instructionRef": {"digest": "sha256:…", "ref": "artifact:…"}, "target": {"adapterId": "opencode", "hostId": "mac-local", "kind": "cli"}}`: copia esos dos objetos tal cual.
3. `managed_tasks_submit` con un `taskKey` nuevo (nunca `key`), por ejemplo `canario-saludo-202610121530` (repo, tema, fecha y hora), y este `assignment`:
   - `target` e `instructionRef`: los de `brief.py`.
   - `inputRevision`: el del paso 1. Si vino `null`, porque el trabajo no tiene repo, usa `{"kind": "artifact", "ref": <instructionRef.ref>, "digest": <instructionRef.digest>}`.
   - `resultContract`: `ready.v1` para implementar o arreglar, `review.v1` para revisar.
   - `continuation`: `{"kind": "requester"}`.
   - `progressBinding`, solo si el trabajo tiene corrida en el tablero (`seguimiento-tablero`): `{"publisherHostId": "mac-local", "corrida": "<c>", "carril": "<carril>", "intento": "<intento>", "ronda": 1}`.
4. `managed_tasks_admit` con el `taskId` y `admissionKey` `<taskKey>-admit`. Contesta `host-pending`.
5. Termina tu turno. Dile a David en una línea el `taskId` y el `modelo` del paso 1. Si `cobro` es `per-token`, dile que ese encargo cobra por token. Si `enFila` es verdadero, dile que hay otro encargo delante.

## Cuando R te despierte

1. `managed_tasks_inspect` con el `taskId`.
2. Pregunta a la Mac qué pasó, con `exec` (`host="node"`):
   ```
   python3 /Users/dn/dev/wt/agent-work-host/scripts/agent-work/encargo.py estado --tarea <taskId>
   ```
   Contesta una línea JSON con el `modelo` que corrió de verdad, leído del proceso que el host lanzó:
   ```
   {"ok": true, "tarea": "<taskId>", "modelo": "zai-coding-plan/glm-5.3-highspeed", "cobro": "subscription", "estado": "acknowledged", "cierre": "AbsenceVerified", "explicacion": null, "permisosNegados": [], "proveedoresLlamados": ["zai-coding-plan"], "carpetaDeSesion": "/Users/dn/dev/<repo>", "salida": null, "logTail": ["…"]}
   ```
   Si algo falló, `explicacion` deja de ser `null` y trae `causa`, `frase` y `accion`.
3. Con resultado (`result.kind` `produced`): léelo con `managed_tasks_artifact_read` (`offset` 0, `length` 4096, en base64; sigue hasta `eof`) y compruébalo en la Mac (el archivo, el commit). Ciérralo con `managed_tasks_resolve`, que lleva solo `receipt` y `decision` (sin `taskId` aparte). El `receipt` es el `resultReceipt` del inspect, tal cual (`taskId`, `generation` y `resultDigest`). La `decision` es `{"kind": "complete", "evidenceRef": "<result.payload.evidenceRef>"}` si cumple, o `{"kind": "continue", "children": [{"slot": "correccion-1", "assignment": {...}}]}` si hay que corregir, con un brief nuevo hecho con los mismos `briefArgs` y el mismo `target`.
4. Sin resultado y con `explicacion.accion` `cancelar`: `managed_tasks_cancel` con el `taskId` y la `explicacion.frase` como `reason`. El host cierra su sesión de opencode cuando R cancela.
5. Cuéntale a David el resultado, o la `frase`, y el `modelo`.

## Proveedores

- Si David pregunta qué modelos o proveedores puede usar por CLI, corre en la Mac `python3 /Users/dn/dev/wt/agent-work-host/scripts/agent-work/encargo.py proveedores`. Imprime una tabla, no JSON. Dile, por cada fila, la `decisión` (`permitido` o `cerrado`), el `cobro` y la `sesión` (`con-sesion` o `sin-sesion`).
- opencode Go es tu suscripción, la de `main`, y un encargo por CLI nunca la usa: `opencode-go/*` y `opencode/*` están cerrados por orden de David. Si los pide, `preparar` contesta `no-registrar` con su cita. Dile esa `frase` y no busques otra forma de correrlo.
- Si David te pide permitir o cerrar un proveedor, no lo hagas tú y no edites ningún archivo. Dile que eso lo hace Claude en la Mac con `encargo.py permitir` o `encargo.py cerrar`, que dejan su frase citada y salen como un PR. Tú pides encargos, así que no eres quien los autoriza.

## Trampas

- No decidas tú si el trabajo se puede: encárgalo. Si pide tocar algo fuera del repo, el host lo niega y `estado` te lo dice. Hacerlo con tu `exec` se salta esa guarda.
- En esta ruta nadie aprueba permisos, ni tú ni nadie en la Mac. Si opencode niega uno, el encargo termina sin resultado y `estado` lo nombra en `permisosNegados` y en la `frase`: cancela y díselo a David.
- `resolve` necesita un resultado. Una tarea que solo tiene una incidencia se cancela con `managed_tasks_cancel` (`taskId` y `reason`).
- No reenvíes un encargo que falló ni teclees en la Mac. Si hay que repetir, es un encargo nuevo con otro `taskKey`, empezando por el paso 1. Un `taskKey` ya usado con otro brief da `Managed task registration conflict`.
- Si David pregunta por un encargo y `managed_tasks_inspect` sigue sin `result` ni `incidents`, corre `encargo.py estado --tarea <taskId>` y dile lo que conteste. Con `"ok": false` y `accion` `esperar`, el host todavía no reclamó la tarea. Con `causa` `sin-host`, el host de encargos no corre: dile la `frase`. Si ese `exec` falla, la Mac no responde: díselo.
- Encarga desde tu sesión, nunca desde un turno `isolated` de cron: R lo rechaza.
