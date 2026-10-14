---
name: raiz
description: Úsala cuando David pida un trabajo de varias partes que se sigue solo hasta terminar (un pedido compuesto, varias filas de un Plans.md, "hazlo todo y avísame"), y cada vez que R te despierte con "Call managed_roots_reconcile". No la uses para un encargo de una parte: ese sigue encargo-cli.
---

# Raíz: un trabajo de varias partes que R lleva hasta el final

Esta skill no está publicada en la Mini. Las herramientas `managed_roots_*` existen solo para los agentes de `managedTasks.rootRequesters`, y esa llave no se pone hasta el corte de SUA-09O.

Una raíz es un plan con sus unidades, la autoridad que David dio y las preguntas que quedan abiertas. R guarda todo, decide cada paso con una regla fija y te despierta cuando hay algo que hacer. Tú traes solo lo que R no puede saber: el plan escrito desde las palabras de David, el brief de cada unidad, lo que comprobaste y las respuestas de David.

## Abrir una raíz

1. Escribe el plan en el mismo turno en que David lo pide. Cada unidad tiene `unitId`, `title`, `dependsOn`, sus criterios (`criterionId`, `text`, `verifier`) y su `scope` (`repos` y `mode`). Un criterio que solo David puede dar por cumplido lleva `verifier` `owner`.
2. Si David nombró filas de un `Plans.md`, no las copies a mano. Córrelo en la Mac (`host="node"`):
   ```
   python3 /Users/dn/dev/wt/agent-work-host/scripts/sistema_agentes/importar_plans.py --repo /Users/dn/dev/<repo> --filas <ids> --alcance <owner/repo>
   ```
   Contesta una línea JSON con `request` y `plan`, listos para `managed_roots_open`. Con `"ok": false`, dile a David el `error` tal cual: una fila depende de otra que no está cerrada.
3. La cobertura: cada frase del pedido de David lleva una entrada, con su papel (`criterion`, `assumption` o `context`) y, para un criterio, los `criterionId` que la cubren. R parte el texto por salto de línea y por punto seguido de espacio. Si falta una, `managed_roots_open` contesta `coverage-incomplete` con la frase: agrégala y repite.
4. La autoridad son las palabras de David: `actions`, `repos`, `accounts`, `destinations`, `deadline` y `mode`. Lo que David no dijo no va. Quién la dio y cuándo lo escribe R desde tu turno.
5. `managed_roots_open` con un `idempotencyKey` nuevo, `request` (`text` es el pedido de David tal cual), `authority` y `plan`. Abre solo desde un mensaje de David: un turno sin remitente no abre.
6. `managed_roots_reconcile` con el `rootId` y las asignaciones de las unidades listas. Cada asignación se prepara como en encargo-cli, pasos 1 y 2 (`encargo.py preparar` y `brief.py`).
7. Dile a David en una línea el `rootId` y qué unidades arrancaron. Termina tu turno.

## Cuando R te despierte

El despertar dice "Managed root <rootId> ... Call managed_roots_reconcile with this rootId."

1. `managed_roots_reconcile` con ese `rootId`. Con `commit: false` solo lees la propuesta.
2. Lee `needs`. Cada `assignment` pide el brief de una unidad (`first`, `correction` o `relay`; un `relay` va con otro modelo). Cada `verify` pide que compruebes esos criterios y traigas un claim por cada uno, con `role` `verifier` o `ci`, `procedure`, `artifactRef` y `outcome`. Vuelve a llamar `managed_roots_reconcile` con esos hechos.
3. Lee `notify`: son preguntas para David. Cada una trae su `exceptionId`, su `type` y sus `options`.
4. Si `state` es `done`, dile a David que la raíz terminó. Si es `waiting` y no hay nada que decir, contesta `NO_REPLY`.

## Avisar a David y leer su respuesta

- Por cada pregunta de `notify`, dile a David una línea: los seis primeros caracteres del `exceptionId`, qué pasó y las opciones.
- Cuando David conteste, traduce sus palabras: `sí` y `si` son `si`; `listo` y `hecho` son `listo`; `salta` es `omitir`; `cancela` es `cancelar`. Las demás opciones van por su nombre.
- `managed_roots_answer` con el `rootId`, el `exceptionId` completo y el `optionId`. Si hay varias abiertas y David no dio el código, pregúntale cuál. R no adivina.
- Una respuesta no cambia. Si David cambia de opinión, `managed_roots_answer` contesta `exception-answered`: díselo.

## Controlar

- `managed_roots_control` pausa (`pause`), reanuda (`resume`) o cancela (`cancel`) con la `expectedControlEpoch` que leíste. `restrict` estrecha la autoridad. Nunca la amplía: para más autoridad hay que abrir otra raíz.
- Después de `/new`, `managed_roots_recover` recupera tus raíces sin nombrarlas.
- Un efecto (push, correo) se inicia con `managed_roots_effect` `step` `start` y se asienta con `step` `settle`. Si R contesta `authority`, no lo hagas: espera la pregunta y la respuesta de David.
