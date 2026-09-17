# Camino feliz del producto (mapa de una página)

Estatus: mapa de encaminamiento. Cada paso nombra la skill autoritativa y NO repite sus pasos; el detalle vive en la skill. La regla de ruteo 6.1 vive en `goncloud-workspace-main/SOUL.md`; este mapa se limita a encaminar.

## Flujo principal

| # | Paso | Skill autoritativa | Cierre del paso |
|---|---|---|---|
| 1 | Pedido de David a main | — | El pedido está en el canal de main. |
| 2 | Clasificación (regla de ruteo 6.1) | `goncloud-workspace-main/SOUL.md` (regla de ruteo con desempate a–e + roster de 8 líneas) | El pedido queda clasificado; main escribe en su reporte la regla aplicada y, si hubo empate, la elección (desempate e). |
| 3 | Brief al carril | `agents/main/agent/workshop-skills/agent-dispatch/SKILL.md` | El brief trae repo, rama, base, alcance, lo prohibido y la orden citada de David. |
| 4 | PR por cadena (implementer → verifier → reviewer) | `agents/main/agent/workshop-skills/agent-dispatch/SKILL.md` | PR abierto, CI verde, cross-review y CodeRabbit limpios, `APPROVE lead <sha>` en el PR. |
| 5 | Verify (si `verify/` existe en el repo) | `verify/` del repo (LEEME y Drive; correr solo de la Mac, nunca por ssh) | `verify/Evidence.txt` con corrida real contra el SHA del PR. Sin `verify/`: el paso no aplica y se declara. |
| 6 | Resumen a David | `agents/main/agent/workshop-skills/owner-report-delivery/SKILL.md` | Entrega confirmada (`ok:true` + `messageId`). |
| 7 | Go/no-go | Cláusulas en `agents/main/agent/workshop-skills/agent-dispatch/SKILL.md` — escritas por el carril E; si esas líneas aún no están mergeadas, el texto exacto es desconocido y el mapa solo deja el ancla: no las redacta. | El go/no-go es de un solo tipo "merge y deploy" para openclaw y los 3 workspaces (merge = deploy por el sync); y de dos tipos separados, "merge y luego deploy", para Orbit y accounting. |
| 8 | Merge por implementer con la orden citada | `agents/implementer/agent/workshop-skills/saikit-cierre-pr/SKILL.md` | PR `MERGED` confirmado desde el remoto con state + mergedAt; nunca un merge por parte de main. El cierre posterior del PR (ledger/log, cuando el repo lo lleva) sigue `agents/main/agent/workshop-skills/post-merge-closure/SKILL.md`. |
| 9 | Deploy por ingenieria | `agents/ingenieria/agent/workshop-skills/goncloud-ssh-ops/SKILL.md` | Smoke verde (código HTTP) y service/container arriba. |
| 10 | "Live <SHA> en <URL>" | Datos de la tabla de máquinas de 6.3 en `goncloud-workspace-main/AGENTS.md`; si esa tabla aun no está mergeada, el dato se toma del texto de la fila del PR A, o se escribe `unknown`. | Mensaje "Live <SHA> en <URL>" a David con el SHA mergeado y la URL viva de la tabla (o unknown). |

Regresión: una regresión reportada después del paso 10 vuelve al brief (paso 3). Esa cláusula de regresión vive en `agents/main/agent/workshop-skills/agent-dispatch/SKILL.md` (carril E); este mapa no la redacta.

## Variantes

| Variante | Ruta |
|---|---|
| Solo investigar (sin código) | Dispara a ingenieria; termina en el diagnóstico, nunca abre PR; el resumen a David viaja por owner-report-delivery. |
| Fix en PR ya abierto | Dispara a la cadena (agent-dispatch, misma lane, se anexan commits al mismo PR); after-review rounds re-validan. |
| Operaciones sin código | Dispara a operaciones; termina en resumen a David; no hay PR ni deploy. |

## Bloqueos → acción

(vacio)
