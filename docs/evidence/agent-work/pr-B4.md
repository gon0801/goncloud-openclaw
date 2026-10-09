# B4: resultados, rutas gestionadas y cadena completa (T8, T9, T10)

Cuerpo del PR de `encargos/b4` a `main`. Lo abre el cierre del bloque con `gh pr create --body-file docs/evidence/agent-work/pr-B4.md`, después de la batería del bloque (`B4-bateria`, plan `:284`).

Cubre T8 (7/7), T9 (10/10) y T10 (7/8 al escribir esto; `:284` lo cierra `B4-bateria`) del plan `docs/superpowers/plans/2026-09-30-encargos-agentes.md`.

## Dependencias exactas

- G: la rama `encargos/b4` desde `77fafb0f66e595d6a4812c3591d09627315dde82`. El par de aceptación es G `7e1b1476c9909a6ef90ea42b164846e248b7253c`. Después de ese commit solo cambia prosa de evidencia, y el estricto lo comprueba.
- R: `978355503c44313536ab4cd03a6bfb7a5423404b` en la rama `feat/agent-work-integration` de `/Users/dn/dev/openclaw-agent-work-integration`, sobre la base pública `c074824a27c96d3983043f9eeb33823cd1772d8c` (`v2026.9.7`). A R no se le hace push nunca. El cierre del bloque lo respalda con `git bundle` y verifica que el bundle contenga ese SHA.
- La batería de R corre sobre ese mismo SHA de R: son nuestras pruebas y sus importadores directos (`bateria-r-objetivos.sh`), no la suite completa de OpenClaw.

## Evidencia

- La matriz `docs/evidence/agent-work/acceptance.md`: una fila por escenario y por frontera del spec, más los casos de T10. Todas las filas del bloque están en `completa` con el mismo par.
- La corrida del par, `acceptance-pair.json`, con un log por comando en `par-final/`. Corre una vez cada una de las 51 pruebas que cita la matriz contra R construido en el par y limpio, y las 51 salieron en verde. `bash scripts/tests/test-agent-work-e2e.sh acceptance` exige esa corrida y la lee.
- Recibos por tarea: `T8.md`, `T9.md`, `T10-*.md`. Los logs de rojo, verde y mutación de cada encargo están en `B4-*.log`.

## Fuera de este bloque

- A17, takeover y reversa con eventos en vuelo: T11 (`cutover_fencing`, plan `:298`).
- A8 y T10:idle_72h, cero inferencia de vigilancia medida con contadores externos: T12 (plan `:316`, 30 minutos en vivo). La decisión es de David, del 2026-10-09. Aquí queda el cero a nivel de despacho con timers falsos (`idle_72h`) y hooks repetidos (`hook_is_observation`), que corren en el par.

## Limitaciones de adaptadores, dichas como tales

- Los CLI de las pruebas de punta a punta son dobles en tmux, y el modelo del solicitante es un guion del arnés o contesta NO_REPLY. El revisor de `review_tail_restart` también es un doble.
- Un despertar o una entrega duplicados se detectan solo dentro de la espera final de 20 s.
- En las fronteras B2 y B6, el host reiniciado corre dentro del proceso de la prueba.
- `delivery_latency_r` mide una corrida real contra R y no demuestra el peor caso: el peor caso del sondeo lo fija `delivery_latency`, con reloj controlado. El bucle de esa prueba corre sin `cli_claim` ni `cli_watch`. Una pasada que también reclama y entrega midió unos 4,3 s.
- La mitad de A2 sobre "los mismos hijos" se cumple en vacío (NO_REPLY). "Una sola vez" lo fija el contador de despertares.
- El no reemplazo del lado de R (`managed-task.host-closure.test.ts`) no se corre desde G. La readmisión de una tarea cancelada no se alcanza sin desarmar tres guardas de R: la prueba fija la causa del rechazo.
- `test_resource_close_real_launchd_label_stays_pending` se salta sin una sesión de login real de la cuenta `agentes` (`user/502 Background-only: bootstrap/load give EIO 5`). Es el único salto de la corrida del par, contado en `resource_close`.

## Admisión productiva deshabilitada

- `limits.json`: `productionProfile: null` y `productionAdmissionEnabled: false`.
- `coverage.json`: ninguno de los 7 adaptadores CLI está certificado en ninguno de los 2 hosts. `test_no_inventory_cli_is_certified_so_no_cli_route_or_claim_opens` comprueba que las 14 rutas CLI se rechazan al rutear y al reclamar sin llegar al Gateway (A10).
- No se toca la instalación viva: T11 prepara la instalación y T12 la ejecuta con autorización.

## Hallazgos abiertos

Están en la tabla de `followups.md`, cada uno con su condición de cierre y su destino (T11, T12 o la batería). Los resueltos en este bloque están en las secciones "Resueltos en …" del mismo archivo.

## Batería del bloque

La agrega `B4-bateria` (plan `:284`): el artefacto nativo con integridad registrada y una sola corrida de las baterías completas.
