# Explorador B: programa anterior (U3b, U4, U5, U6, Encargos, Fase 17, Fase 20) y cómo lo reorganiza SUA

## Programa vigente en origin/main (77fafb0)
- Plans.md "Ruta activa única" :3-57. Encargos :36 cc:WIP "parcial, sin adopción productiva". U3b/U4/U5/U6 :37-40 cc:TODO. Orden :42-57: "U3 → U3a → U3b → U4; U3b arranca solo con U3a cerrada al 100% (decisión de David, 2026-09-30)" (:45); "La base de encargos durables se integra y verifica antes de U3b y de la integración OpenClaw de U4" (:47). Detalle: Fase 17 :795, Fase 19 :850, Fase 20 :879, Fase U6 :934. "17 = U4/U5" (:59).
- U3b/Fase 20: plan 2026-09-29-director-corrida.md (20.0-20.11); diseño con tabla "Decisiones de David" (11) :313-329 y "Qué se borra" :404-430.
- U4/U5/Fase 17: plan 2026-09-22-centro-tareas.md (división por host :26-65; "Reject" :268-270 incluye "merge automático"); diseño con 10 escenarios de aceptación :207-234.
- U6: 2026-09-24-u6-metas-autonomas.md (dependencias :44-79; 12 criterios de aceptación integral :323-346).
- Encargos: 2026-09-30-encargos-agentes.md (B0-B5 :93-104; "Integra esta base antes de U3b y del adaptador OpenClaw de U4" :106-116). Matriz docs/evidence/agent-work/compatibility-u3b-u6.md.

## SUA
Worktree flota-poteto, rama feat/flota-poteto, HEAD e5cae2d = cabeza del PR #247 (draft). SUA sin commit encima. e5cae2d (2026-10-04) agregó "Fase F — Política de flota" (F.0-F.4) que decía "No se crea otra cola ni se reemplaza el orden de U4/U6". Material de codex en /Users/dn/.claude/orchestrate/plan-unificado-agentes/ (architecture-task.md, decisions.tsv, crossjudge.md, final-review.md REQUEST_CHANGES, delta-review.md APPROVE).

## Orden viejo: quién y cuándo
- 2026-09-22 Ruta activa única.
- 2026-09-24 David pide planear U6 como lo que falte de U2-U5; prioridad U2, U3, U3a, U4, U5, U6; U6 depende de U4 (OpenClaw) y U5 (Hermes).
- 2026-09-26 David: U3a tras U3 y antes de U4; LobsterBoard original antes de UI propia.
- 2026-09-29 Decisiones de David para Fase 20 (35c0661, PR #227). #9 original: "Hasta 5 rondas con el mismo implementador; relevo con otras 5; después pregunta a David".
- 2026-10-01 8358fac cambió #9 a stop2; llegó a main con PR #242 (cdefb94, 2026-10-02).
- 2026-09-30 David: "U3 → U3a → U3b → U4; U3b solo con U3a al 100%".
- 2026-10-01 a19501c agregó fila Encargos y "encargos antes de U3b y de la integración OpenClaw de U4" (PR #242). No atribuida a David explícitamente.
- 2026-10-04 Fase F (solo en PR #247): no reemplaza el orden U4/U6.
- Orden viejo efectivo: U3 → U3a → base de Encargos verificada por perímetro → U3b → U4 → U5 → U6. U4 no espera todo U3b.

## Orden nuevo SUA
00 → 01 → 02 → 03 → 04; 05 (02,03); 06 (02); 07 Hermes (solo 00, paralelo); 08 (05); 09O (04,05,06); 09H (+07); 10O (08, 09O); 10H (09H); 11 (10O, 10H).
Lógica declarada (Plans.md flota-poteto :41-44): "orden histórico U3b → flota → U4/U5 → U6 queda sustituido… SUA define primero estado, aceptación y control; después integra trabajadores, calidad y panel; publica y acepta cada host por separado". Diseño :58 "Metas, aceptación y control desde la base". Codex con arena architect: dos candidatos A y B empatados 23/25, juicio cruzado eligió B. Encargo: "El usuario permite replantear todos los planes" y "pidió SOLO diseño". Ningún documento registra una decisión fechada de David que apruebe el orden SUA.

## Tabla de mapeo (cob:NN = líneas de cobertura.md)
| Vieja | Bloque SUA | Se conserva | Se elimina/sustituye | Cambia |
|---|---|---|---|---|
| 20.0 medir despertar | 00 | medir despertar, /new, cleanup, costo | — | parte del inventario |
| 20.1 director.py puro | 01, 02 | leyes: no merge sin aprobado (I13), cupo (I20), no repetir efecto (I06) | director Python en G | controlador local en R src/agents/goals/; contradice decisión #2 de David "construir sobre corrida.sh / reconcile() único decisor" |
| 20.2 merge libre | 05 | CI y revisor del head exacto, check-run del bot | tabla de preaprobaciones | se retira tras migrar consumidores |
| 20.3 cupo global | 01 | tope 4 y par atómico | — | corrige fixture viejo (con 3 de 4 ocupadas no se admite un par) |
| 20.4 sesiones y teclas | 03, 05 | registrar sesión antes de entregar, teclas_lock | revisor con escritura | revisor solo escribe resultado (I09) |
| 20.5 observación y sombra | 02, 09O | sombra | — | autoridad en el host |
| 20.6 ciclo vivo | 01/02/05 | submit/report/resolve | nudge legacy, relojes con modelo | — |
| 20.7 publicar y desplegar | 05, 08 | PR, CI, rebase, merge, deploy, ledger | — | catálogo de efectos por repo |
| 20.8 excepciones | 02 | 11 clases, ID, respuesta única, reaviso 60 min | — | CONFIRMAR_PLAN ya no por tamaño; BLOQUEANTE_REPETIDO sujeto a política nueva |
| 20.9 entrada de claw | 02, 09O | pedido, plan, importación de filas | confirmación por tamaño (decisión #5) | decide la autoridad |
| 20.10 primera corrida y retiro del vigía | 09O, 10O | tres entradas, corte por generación | "cierre-de-fase 20 en VERDE" y Promesa por Telegram | FUNCIONA "cuando corresponda" |
| 20.11 Orbit | 08, 10O | script deploy, salud, reversa | — | — |
| 17.0/17.1 | 00, 06 | LobsterBoard primero | — | — |
| 17.2 | 01, 06 | adaptador OpenClaw | — | — |
| 17.3 Hermes | 07, 10H | Hermes sin gateway OpenClaw | — | alcance ampliado: Hermes con su propio controlador; corre en paralelo desde 00 |
| 17.4 supervisor | 01/02/06/07 | recuperación | supervisor separado | scheduler y dueño nativos |
| 17.5 panel | 06 | panel solo lectura | — | — |
| 17.6-17.8 | 09/10 O/H | instalación por host, reversa, aceptación con el otro host caído | — | — |
| U4-A01..A10 | I01-I24 | los 10 | — | — |
| U6.0-U6.5 | 00/01/02/03/06 | inventario, DAG, autoridad, avance/reparación, pausa/cancelación con época, cierre agregado | — | U6.1 pasa de último a la base; fan-in atómico A+B→C en R |
| U6.6 | 09/10 | 12 escenarios | launcher U6 | alias SUA |
| U6-A01..A12 | cob:75-88 | 11 de 12 | — | A11 cambia: stop2 → v2 (inactiva sin recibo) |
| F.0-F.4 | 00/03/04/09/10 | — | código del PR #247 no aprobado | — |
| Encargos T0-T12 | NO están en las 39 filas; solo "residuales nativos y de corte T1-T12 se integran en SUA-00/01/09 por perímetro" (cob:149-150); Plans.md flota-poteto :38 "Base para SUA" | código y recibos | — | deja de ser compuerta separada antes de U3b; SUA-09 cita mecanismos T11-T12 |

## Estado real de Encargos
B0 PR #242, B1 #243, B2 #245, B3 #246 (77fafb0): T0-T7 en main. En encargos/b4 @209a008: T0-T8 completas; T9 5/10 (faltan correr en rojo, migrar entradas, conservar rutas viejas, cli_silent_failure, cli_delivery_acceptance); T10 1/8; T11 0/7; T12 0/12. Loop activo: B4-14-r1 con LISTO (G=82f26f4, R=6e3d428), revisión pendiente. B5 (T11-T12) pendiente.

## Boundaries
SUA no reabre U0-U3a, U1/sync, Fase 14 ni evidencia de encargos. Banner de Encargos distinto: "Integración 2026-10-05", T0-T12 sigue siendo base reutilizable, "No se ejecutan dos programas sobre la misma entrada". Decisor pasa de corrida_worker.reconcile() en G (Python) a controlador en R (TypeScript); "No queda un decisor Python activo".

## No obvio
1. SUA vive en la rama del PR #247 y rechaza su código.
2. Fase F duró un día (agregada 10-04 con "no se reemplaza el orden de U4/U6"; reemplazada 10-05).
3. El orden "histórico" que cita SUA (U3b → flota → U4/U5 → U6) nunca estuvo en main.
4. Política de rondas va por su tercer valor: 5+5 (David 09-29) → stop2 (8358fac 10-01) → v2 4 ciclos.
5. Bases mezcladas: R=6e3d428 es la cabeza aprobada en B4; G=e5cae2d no tiene los commits G de B4 (T8 puente de progreso y director_handling; T9 main_cli_loop f385f21; incidencias de host 209a008, 82f26f4).
6. SUA no menciona el loop de encargos; B4 agrega transiciones al reconciliador Python de G que SUA planea retirar.
7. encargos/b4 y flota-poteto editan el mismo archivo del plan de encargos (banner vs casillas).
8. arranque-de-fase.sh :52-54 rechaza fases no numéricas; cierre-de-fase.sh busca filas | N.x |; bloques SUA no están en Plans.md y la fila SUA perdió [lane:] y marca cc:.
9. SUA resuelve la contradicción Fase 17 (rechaza merge automático) vs Fase 20 (lo exige) a favor de merge por política.
10. 20.6 se apoyaba en director_handling; SUA dice que no está en test-runtime.sh, aunque encargos/b4 lo cerró con test-agent-work-integration.sh (f04ccba).
11. "17 = U4/U5" sin actualizar.

## Obligaciones viejas que SUA no hereda explícitamente
1. Encargos T0-T12 sin fila por tarea; no aparecen (grep=0): ventana de 30 min sin inferencia de vigilancia (T12), cambio de plantilla prompt-claw para no crear <loop>-vigia, perfil limits.json. cli_silent_failure, cli_delivery_acceptance, review_tail_restart solo genéricos vía I22/I09.
2. Punto (17) de 19.3 diferido a U4: tablero no abre en el celular (gateway en loopback, token solo en header). No está en SUA.
3. De 20.10: cierre-de-fase 20 en VERDE; Promesa: David pide por Telegram en prosa y recibe el cambio mergeado y desplegado sin preguntas fuera de NECESITO; claw despierta solo por excepción con tokens medidos. "Telegram" no aparece en SUA.
4. Decisiones de David del 09-29 cambiadas: #2 (sobre corrida.sh → R), #5 (CONFIRMAR_PLAN → autoridad), #9 (rondas), #10 ("repo nuevo siempre pregunta" → "sin autoridad").
5. "Una fila CLI no certificada sigue deshabilitada" y "par G/R y capacidades acreditados" (SUA-03 lo cubre como ruta visible e inelegible).

## Preguntas abiertas
¿El loop de encargos sigue hasta cerrar o se detiene? ¿David aprobó el orden SUA o solo pidió diseño? ¿Con qué comando se abre/cierra un bloque SUA? ¿Adónde va el panel móvil? ¿Cómo se coordina SUA-01 con los escritores de encargos sobre managed-task.* en R (el plan de encargos prohíbe escritores paralelos sobre R.taskStore)? ¿Las transiciones T8 en corrida_worker quedan como compatibilidad o se migran?
