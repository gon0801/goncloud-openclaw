---
name: native-harness-orchestration
description: Dirige ingenieria por los harnesses nativos del registro de workers de la Mac (scripts/mac/workers.v1.json) con reconciliation, evidencia y merge autorizado; conserva la cadena legada con CORRIDA_NATIVE_ROUTING=off.
---

# Orquestación nativa de ingeniería (Fase 14)

Dirige carriles de ingeniería por harnesses nativos de la Mac: los workers del
registro `scripts/mac/workers.v1.json`. Cursor salió del registro el 2026-09-29
por decisión de David; vuelve solo con su propio humo real `passed`. La máquina
ejecuta; este contrato decide. Tabla de decisión ejecutable: cada paso de
efecto EMPIEZA reconciliando (`corrida.sh reconciliar <id>`) y TERMINA escribiendo
su observación (`observed.*` en el registro).

## Reglas que no se negocian

- **Reconciliación antes de efectos:** ningún efecto se lanza sin un
  `reconciliar` previo que lo proponga.
- **Explicación del selector:** cada selección se registra con su puntaje y
  sus razones (`explicacion del selector`), nunca solo el ganador.
- **Tope de cuatro** sesiones externas activas; el quinto carril espera.
- **Nunca cambia de harness en silencio:** un relevo exige handoff de
  disponibilidad registrado (loop §9) con el estado del predecesor y sus
  hijos; el cambio se anuncia, no se descubre.
- **Fallo de quota/auth/lanzador** va al siguiente candidato compatible no
  intentado, preservando las mediciones por host (lo medido en Muse queda en
  Muse).
- **Jamás manda secretos en los briefs:** los briefs pasan redacción y los
  tokens viven en el gateway, no en pantalla ni en texto.
- **Main nunca mergea ni despliega:** delega merge/deploy por la compuerta
  con `authorization_ref` en alcance, recibo `saikit-entrega.v1` vigente y CI
  del head; `expectedHeadOid` fija la mutación. Con el kit apagado
  (`modo_recibo: ci-y-revisor` en `preaprobaciones.v1.json`, David
  2026-09-28), el recibo lo reemplaza un veredicto de revisor sobre el mismo
  head: DeepSeek completo sin High/Critical abiertos o una review de
  CodeRabbit de ese commit.
- **Revisión cruzada local antes del primer push**, y el loop de corrección
  de CodeRabbit corre en el mismo PR (delta review, no nueva revisión).
- **Modelo y effort visibles:** el tablero y la selección muestran el `model` y el `effort` del worker elegido; `reported_model` es lo que la CLI reporta y se registra aparte (14.13d). Sin flag de effort en la CLI queda `null` y el tablero dice que corre el de la CLI. `adaptador start` publica el worker del carril y el porqué de su selección en el tablero; un relevo lanzado por `reconciliar` lo anuncia una vez por Telegram.
- **Canary vivo verificado** antes de declarar éxito; un canary fallido
  obliga reversa documentada.
- **Routea off a la cadena existente:** con `CORRIDA_NATIVE_ROUTING=off` o el
  gate de rollout por etapas sin aprobar, se usa la cadena agent-dispatch de
  siempre; nada de esta skill corre.
- **Ruta pre-install/manual** de Fases 14 y 23: sigue usable sin invocar
  scripts que esta fase no instaló.

## Tabla de decisión (comandos exactos)

| Efecto | Comando | Cierra con |
|---|---|---|
| Abrir corrida | `corrida.sh abrir <id> --runbook ... --vigia claw --cli-modos <tsv>` | registro abierto |
| Preflight | `corrida.sh preflight <id>` | `APTO` / `NO APTO <razones>` |
| Preparar carril | `corrida.sh preparar-carril <id> <carril> <repo> [--read-only]` | reserva escrita |
| Seleccionar worker | `corrida.sh seleccionar <id> <carril> --request <req> --state <st>` | `winner` + score + razones de `corrida-worker.py select`, guardados en el carril |
| Arrancar sesión | `corrida.sh adaptador start <id> <carril> <worker> <sesion> <wt> <brief>` | `session` registrada |
| Entregar brief | `corrida.sh adaptador deliver <id> <carril> <worker> <sesion> <brief>` | `accepted`/`blocked` |
| Terminal | `corrida.sh mostrar-terminal <id> <carril>` | visible/degraded |
| Inspeccionar | `corrida.sh adaptador inspect <id> <carril> <worker> <sesion>` | running/waiting/complete/failed/quota/auth-vencida |
| Reconciliar | `corrida.sh reconciliar <id> --observations <json>` | efectos ejecutados + `CONVERGED`; `REOBSERVAR` tras un efecto externo: observa de nuevo y repite |
| Evidencia | `corrida.sh compuerta <id> <lane> cross-review|push-pr|ci|coderabbit --sha <sha> --evidence <json>` | `ALLOW`/`DENY` + proyección |
| Delegar merge | `corrida.sh compuerta <id> <lane> merge --sha <sha> --evidence <json>` | `ALLOW merge-ok` |
| Deploy | `corrida.sh compuerta <id> <lane> deploy --sha <sha> --evidence <json>` | `ALLOW`/`DENY` |
| Canary / rollback | `corrida.sh compuerta <id> <lane> canary|rollback --sha <sha> --evidence <json>` | veredicto + proyección |
| Archivar | `corrida.sh cerrar <id>` | `archive/<lane>/` completo |
| Cerrar | `corrida.sh cerrar <id>` | `cerrada <id>` |

Ruta anterior (T9 `:265`): la corrida abierta con `--vigia claw` y los CLI arrancados con `adaptador start` y entregados con `adaptador deliver` (`ADAPTADOR-MARCA`) siguen fuera del perímetro gestionado hasta su adopción (T12). Un CLI gestionado entra solo por `Host.apply`: en producción, `claim_cli_once` con `TmuxTransport`; `adaptador deliver-ref` es su transporte alterno por `corrida.sh`. Los dos marcan la sesión con `AGENT_WORK_MANAGED=1`, y sobre esa sesión no se usa `adaptador deliver`.

## Pre-install / manual (Fases 14 y 23)

La ruta pre-install/manual (mediciones por host, canaries de un solo host)
corre sin este paquete: usa los comandos del destino y declara lo no
verificado. Nada de esta skill obliga a instalar scripts de la Fase 14 para
esa ruta.
